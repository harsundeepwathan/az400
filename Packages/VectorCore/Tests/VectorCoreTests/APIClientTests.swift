import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import VectorCore

/// Scripted server: each request is answered by the handler, and recorded.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var handler: (URLRequest) throws -> (Int, String)

    init(_ handler: @escaping (URLRequest) throws -> (Int, String)) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request) }
        try await Task.sleep(for: .milliseconds(5))
        let (status, body) = try handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func paths() -> [String] { lock.withLock { requests.map { $0.url!.path } } }
}

final class APIClientTests: XCTestCase {
    let base = URL(string: "https://api.example.com")!
    let now = Date(timeIntervalSince1970: 1_790_000_000)

    func session(_ access: String, refresh: String = "refresh-2") -> String {
        #"{"access_token":"\#(access)","expires_in":3600,"refresh_token":"\#(refresh)","user_id":"u1"}"#
    }

    let me = #"{"user_id":"u1","analytics_opt_out":false,"entitlement":{"tier":"free"},"scans":{"tier":"free","used":1,"limit":3,"remaining":2,"window":"week","resets_at":null}}"#

    func testSignInStoresSessionAndAuthorizesRequests() async throws {
        let store = InMemoryTokenStore()
        let transport = StubTransport { request in
            switch request.url!.path {
            case "/v1/auth/apple": return (200, self.session("access-1"))
            case "/v1/me":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
                return (200, self.me)
            default: return (404, "{}")
            }
        }
        let api = APIClient(baseURL: base, transport: transport, tokens: store, now: { self.now })
        let userID = try await api.signInWithApple(identityToken: "apple-jwt", nonce: "n")
        XCTAssertEqual(userID, "u1")
        XCTAssertEqual(store.load()?.accessExpiresAt, now.addingTimeInterval(3600))
        let account = try await api.account()
        XCTAssertEqual(account.scans.remaining, 2)
        XCTAssertEqual(account.tier, .free)
    }

    func testExpiredAccessTokenRefreshesOnceForConcurrentRequests() async throws {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "old", refreshToken: "refresh-1", userID: "u1", accessExpiresAt: now.addingTimeInterval(-10)))
        let transport = StubTransport { request in
            if request.url!.path == "/v1/auth/refresh" { return (200, self.session("fresh")) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
            return (200, self.me)
        }
        let api = APIClient(baseURL: base, transport: transport, tokens: store, now: { self.now })
        async let a = api.account()
        async let b = api.account()
        async let c = api.account()
        _ = try await (a, b, c)
        XCTAssertEqual(transport.paths().filter { $0 == "/v1/auth/refresh" }.count, 1, "one refresh for all waiting requests")
        XCTAssertEqual(store.load()?.refreshToken, "refresh-2", "rotated token is stored")
    }

    func testUnauthorizedResponseRefreshesAndRetriesOnce() async throws {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "revoked", refreshToken: "refresh-1", userID: "u1", accessExpiresAt: now.addingTimeInterval(3000)))
        let transport = StubTransport { request in
            switch (request.url!.path, request.value(forHTTPHeaderField: "Authorization")) {
            case ("/v1/auth/refresh", _): return (200, self.session("fresh"))
            case (_, "Bearer fresh"): return (200, self.me)
            default: return (401, #"{"error":"invalid_token"}"#)
            }
        }
        let api = APIClient(baseURL: base, transport: transport, tokens: store, now: { self.now })
        _ = try await api.account()
        XCTAssertEqual(transport.paths(), ["/v1/me", "/v1/auth/refresh", "/v1/me"])
    }

    func testRejectedRefreshSignsOut() async {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "old", refreshToken: "stolen", userID: "u1", accessExpiresAt: now.addingTimeInterval(-10)))
        let transport = StubTransport { _ in (401, #"{"error":"refresh_token_reused"}"#) }
        let api = APIClient(baseURL: base, transport: transport, tokens: store, now: { self.now })
        do {
            _ = try await api.account()
            XCTFail("Expected sign-out")
        } catch {
            XCTAssertEqual(error as? APIError, .signedOut)
        }
        XCTAssertNil(store.load(), "local session is cleared")
    }

    func testErrorMapping() {
        let quota = Data(#"{"error":"scan_quota_exceeded","allowance":{"tier":"free","used":3,"limit":3,"remaining":0,"window":"week","resets_at":"2026-10-08T09:00:00.000Z"}}"#.utf8)
        guard case .scanQuotaExceeded(let allowance) = APIClient.error(status: 402, data: quota, authorized: true) else {
            return XCTFail("Expected quota error")
        }
        XCTAssertEqual(allowance?.remaining, 0)
        XCTAssertNotNil(allowance?.resetsAt)
        XCTAssertEqual(APIClient.error(status: 429, data: Data(#"{"error":"rate_limited"}"#.utf8), authorized: true), .rateLimited(retryAfter: nil))
        XCTAssertEqual(APIClient.error(status: 429, data: Data(#"{"error":"rate_limited","retry_after_seconds":30}"#.utf8), authorized: true),
                       .rateLimited(retryAfter: 30))
        XCTAssertEqual(APIClient.error(status: 503, data: Data(), authorized: true), .unavailable)
        XCTAssertEqual(APIClient.error(status: 400, data: Data(#"{"error":"unsupported_image"}"#.utf8), authorized: true),
                       .rejected(status: 400, code: "unsupported_image"))
    }

    func testMealScanMapsErrorsAndCarriesScanID() async throws {
        let store = InMemoryTokenStore(AuthTokens(accessToken: "a", refreshToken: "r", userID: "u1", accessExpiresAt: now.addingTimeInterval(3000)))
        var reply: (Int, String) = (200, #"{"scan_id":"s1","items":[{"name":"White rice","grams":200,"calories":260,"protein":5.4,"carbs":56.4,"fat":0.6,"confidence":0.85,"alternatives":[]}],"allowance":{"tier":"free","used":1,"limit":3,"remaining":2,"window":"week","resets_at":null}}"#)
        let transport = StubTransport { _ in reply }
        let recognizer = RemoteMealRecognizer(api: APIClient(baseURL: base, transport: transport, tokens: store, now: { self.now }))
        let analysis = try await recognizer.analyze(imageData: Data([0xff, 0xd8, 0xff]))
        XCTAssertEqual(analysis.scanID, "s1")
        XCTAssertEqual(analysis.allowance?.remaining, 2)
        XCTAssertEqual(analysis.items.first?.grams, 200)

        for (response, expected) in [((402, #"{"error":"scan_quota_exceeded"}"#), MealRecognitionError.quotaExceeded),
                                     ((503, #"{"error":"busy"}"#), .busy),
                                     ((200, #"{"scan_id":null,"items":[]}"#), .noFoodDetected)] {
            reply = response
            do {
                _ = try await recognizer.analyze(imageData: Data([0xff, 0xd8, 0xff]))
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? MealRecognitionError, expected)
            }
        }

        let signedOut = RemoteMealRecognizer(api: APIClient(baseURL: base, transport: transport, tokens: InMemoryTokenStore()))
        do {
            _ = try await signedOut.analyze(imageData: Data([0xff]))
            XCTFail("Expected sign-in required")
        } catch {
            XCTAssertEqual(error as? MealRecognitionError, .signInRequired)
        }
    }

    // MARK: Analytics

    func testEventEncodingMatchesServerContract() throws {
        let event = AnalyticsEvent(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, name: .workoutCompleted,
                                   occurredAt: now, properties: ["sets": 18, "pr": true, "template": "program"])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as! [String: Any]
        XCTAssertEqual(json["id"] as? String, "6f9619ff-8b86-d011-b42d-00c04fc964ff")
        XCTAssertEqual(json["name"] as? String, "workout_completed")
        XCTAssertEqual(json["occurred_at"] as? String, "2026-09-21T14:13:20.000Z")
        let properties = json["properties"] as! [String: Any]
        XCTAssertEqual(properties["sets"] as? Double, 18)
        XCTAssertEqual(properties["pr"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(AnalyticsEvent.self, from: JSONEncoder().encode(event)), event)
    }

    func testEventNamesMatchBackendList() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../backend/api/src/events.ts").standardized
        let text = try String(contentsOf: source, encoding: .utf8)
        guard let start = text.range(of: "EVENT_NAMES = ["), let end = text.range(of: "] as const", range: start.upperBound..<text.endIndex) else {
            return XCTFail("EVENT_NAMES not found")
        }
        let backend = text[start.upperBound..<end.lowerBound].split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("\"") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\",")) }
        XCTAssertEqual(Set(backend), Set(AnalyticsEventName.allCases.map(\.rawValue)))
        XCTAssertEqual(backend.count, AnalyticsEventName.allCases.count)
    }

    func testEventQueueBatchesKeepsFailuresAndRespectsOptOut() async {
        final class Box: @unchecked Sendable { var enabled = true; var fail = false; var uploaded: [[AnalyticsEvent]] = []; var persisted = 0 }
        let box = Box()
        let queue = EventQueue(isEnabled: { box.enabled },
                               upload: { batch in
                                   if box.fail { throw URLError(.notConnectedToInternet) }
                                   box.uploaded.append(batch)
                               },
                               persist: { box.persisted = $0.count })
        for _ in 0..<120 { await queue.track(AnalyticsEvent(name: .setLogged)) }
        XCTAssertEqual(box.persisted, 120)

        box.fail = true
        await queue.flush()
        let afterFailure = await queue.count
        XCTAssertEqual(afterFailure, 120, "nothing lost while offline")

        box.fail = false
        await queue.flush()
        XCTAssertEqual(box.uploaded.map(\.count), [50, 50, 20])
        let remaining = await queue.count
        XCTAssertEqual(remaining, 0)

        box.enabled = false
        await queue.track(AnalyticsEvent(name: .appOpened))
        let optedOut = await queue.count
        XCTAssertEqual(optedOut, 0, "nothing is queued after opting out")
    }
}
