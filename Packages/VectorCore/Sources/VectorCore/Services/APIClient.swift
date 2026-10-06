import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends a request and returns the body and HTTP response. `URLSession` in
/// the app, a stub in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public struct AuthTokens: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var userID: String
    public var accessExpiresAt: Date

    public init(accessToken: String, refreshToken: String, userID: String, accessExpiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userID = userID
        self.accessExpiresAt = accessExpiresAt
    }
}

/// Where tokens live: the Keychain in the app, memory in tests.
public protocol TokenStore: Sendable {
    func load() -> AuthTokens?
    func save(_ tokens: AuthTokens?)
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?
    public init(_ tokens: AuthTokens? = nil) { self.tokens = tokens }
    public func load() -> AuthTokens? { lock.withLock { tokens } }
    public func save(_ tokens: AuthTokens?) { lock.withLock { self.tokens = tokens } }
}

/// Server-side scan allowance. The server is the authority; the app only displays it.
public struct ScanAllowance: Codable, Hashable, Sendable {
    public var tier: SubscriptionTier
    public var used: Int
    public var limit: Int
    public var remaining: Int
    /// "week" (free, rolling 7 days) or "day" (Pro fair use, rolling 24 h).
    public var window: String
    public var resetsAt: Date?

    public init(tier: SubscriptionTier, used: Int, limit: Int, remaining: Int, window: String, resetsAt: Date?) {
        self.tier = tier
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.window = window
        self.resetsAt = resetsAt
    }
}

public struct Account: Hashable, Sendable {
    public var userID: String
    public var tier: SubscriptionTier
    public var analyticsOptOut: Bool
    public var scans: ScanAllowance
}

public enum APIError: Error, Hashable, Sendable {
    /// No session, or the session was revoked: sign in again.
    case signedOut
    case offline
    case scanQuotaExceeded(ScanAllowance?)
    case rateLimited
    case unavailable
    case rejected(status: Int, code: String)
}

/// Talks to `backend/api`. Handles the session: refreshes the access token
/// shortly before it expires and once more on a 401, with a single refresh
/// in flight however many requests are waiting.
public actor APIClient {
    public let baseURL: URL
    private let transport: HTTPTransport
    private let tokens: TokenStore
    private let now: @Sendable () -> Date
    private var refreshTask: Task<AuthTokens, Error>?

    public init(baseURL: URL, transport: HTTPTransport = URLSession.shared, tokens: TokenStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.baseURL = baseURL
        self.transport = transport
        self.tokens = tokens
        self.now = now
    }

    public nonisolated var isSignedIn: Bool { tokens.load() != nil }
    public nonisolated var userID: String? { tokens.load()?.userID }

    // MARK: Session

    struct SessionResponse: Decodable {
        var access_token: String
        var expires_in: Double
        var refresh_token: String
        var user_id: String
    }

    /// Exchanges a Sign in with Apple identity token for a session.
    /// `nonce` is the raw value whose SHA-256 was given to Apple.
    @discardableResult
    public func signInWithApple(identityToken: String, nonce: String?) async throws -> String {
        var body: [String: String] = ["identity_token": identityToken]
        body["nonce"] = nonce
        let data = try await perform(path: "v1/auth/apple", method: "POST", json: body, authorized: false)
        let session = try store(data)
        return session.userID
    }

    /// Ends the session here and, best effort, on the server.
    public func signOut() async {
        if tokens.load() != nil {
            _ = try? await perform(path: "v1/auth/sign-out", method: "POST", json: Optional<[String: String]>.none, authorized: true)
        }
        tokens.save(nil)
    }

    private func store(_ data: Data) throws -> AuthTokens {
        let session = try JSONDecoder().decode(SessionResponse.self, from: data)
        let tokens = AuthTokens(accessToken: session.access_token, refreshToken: session.refresh_token,
                                userID: session.user_id, accessExpiresAt: now().addingTimeInterval(session.expires_in))
        self.tokens.save(tokens)
        return tokens
    }

    private func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens.load() else { throw APIError.signedOut }
        if !forceRefresh, current.accessExpiresAt.timeIntervalSince(now()) > 60 { return current.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let task = Task { () throws -> AuthTokens in
            do {
                let data = try await self.perform(path: "v1/auth/refresh", method: "POST",
                                                  json: ["refresh_token": current.refreshToken], authorized: false)
                return try self.store(data)
            } catch APIError.rejected(status: 401, _) {
                self.tokens.save(nil)
                throw APIError.signedOut
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.accessToken
    }

    // MARK: Requests

    private func perform<Body: Encodable>(path: String, method: String, json: Body?, authorized: Bool, timeout: TimeInterval = 20) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(json)
        }
        var retried = false
        while true {
            if authorized {
                request.setValue("Bearer \(try await validAccessToken(forceRefresh: retried))", forHTTPHeaderField: "Authorization")
            }
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch {
                throw APIError.offline
            }
            if (200..<300).contains(response.statusCode) { return data }
            if response.statusCode == 401, authorized, !retried {
                retried = true
                continue
            }
            throw Self.error(status: response.statusCode, data: data, authorized: authorized)
        }
    }

    static func error(status: Int, data: Data, authorized: Bool) -> APIError {
        struct Body: Decodable { var error: String?; var allowance: AllowanceDTO? }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let code = body?.error ?? "http_\(status)"
        switch status {
        case 401 where authorized: return .signedOut
        case 402: return .scanQuotaExceeded(body?.allowance?.model)
        case 429: return code == "daily_scan_limit" ? .scanQuotaExceeded(body?.allowance?.model) : .rateLimited
        case 502, 503, 504: return .unavailable
        default: return .rejected(status: status, code: code)
        }
    }

    // MARK: Account

    struct AllowanceDTO: Decodable {
        var tier: String
        var used: Int
        var limit: Int
        var remaining: Int
        var window: String
        var resets_at: String?

        var model: ScanAllowance {
            ScanAllowance(tier: tier == "pro" ? .pro : .free, used: used, limit: limit, remaining: remaining, window: window,
                          resetsAt: resets_at.flatMap(Self.parseDate))
        }

        static func parseDate(_ string: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }
    }

    public func account() async throws -> Account {
        struct Me: Decodable {
            struct Entitlement: Decodable { var tier: String }
            var user_id: String
            var analytics_opt_out: Bool
            var entitlement: Entitlement
            var scans: AllowanceDTO
        }
        let data = try await perform(path: "v1/me", method: "GET", json: Optional<[String: String]>.none, authorized: true)
        let me = try JSONDecoder().decode(Me.self, from: data)
        return Account(userID: me.user_id, tier: me.entitlement.tier == "pro" ? .pro : .free,
                       analyticsOptOut: me.analytics_opt_out, scans: me.scans.model)
    }

    public func setAnalyticsOptOut(_ optOut: Bool) async throws {
        _ = try await perform(path: "v1/me", method: "PATCH", json: ["analytics_opt_out": optOut], authorized: true)
    }

    /// Deletes the account and its server-side data, then ends the session.
    public func deleteAccount() async throws {
        _ = try await perform(path: "v1/me", method: "DELETE", json: Optional<[String: String]>.none, authorized: true)
        tokens.save(nil)
    }

    /// Sends a StoreKit 2 `jwsRepresentation` for server verification.
    public func submitTransaction(_ signedTransaction: String) async throws -> SubscriptionTier {
        struct Response: Decodable { var tier: String }
        let data = try await perform(path: "v1/subscription/transactions", method: "POST",
                                     json: ["signed_transaction": signedTransaction], authorized: true)
        return try JSONDecoder().decode(Response.self, from: data).tier == "pro" ? .pro : .free
    }

    // MARK: Meal scan

    public struct ScanResponse: Sendable {
        public var scanID: String?
        public var body: Data
        public var allowance: ScanAllowance?
    }

    public func scanMeal(jpeg: Data) async throws -> ScanResponse {
        struct Meta: Decodable { var scan_id: String?; var allowance: AllowanceDTO? }
        let data = try await perform(path: "v1/meal-scan", method: "POST", json: ["image": jpeg.base64EncodedString()],
                                     authorized: true, timeout: 60)
        let meta = try? JSONDecoder().decode(Meta.self, from: data)
        return ScanResponse(scanID: meta?.scan_id, body: data, allowance: meta?.allowance?.model)
    }

    public func submitCorrection(scanID: String, _ correction: ScanCorrection) async throws {
        _ = try await perform(path: "v1/meal-scans/\(scanID)/correction", method: "POST", json: correction, authorized: true)
    }

    // MARK: Analytics

    public func send(events: [AnalyticsEvent], appVersion: String?) async throws {
        struct Batch: Encodable { var app_version: String?; var events: [AnalyticsEvent] }
        _ = try await perform(path: "v1/events", method: "POST", json: Batch(app_version: appVersion, events: events), authorized: true)
    }
}
