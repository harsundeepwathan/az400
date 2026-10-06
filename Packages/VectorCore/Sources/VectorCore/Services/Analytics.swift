import Foundation

/// Product events the server accepts (mirrors `EVENT_NAMES` in backend/api).
public enum AnalyticsEventName: String, Codable, CaseIterable, Sendable {
    case onboardingCompleted = "onboarding_completed"
    case workoutStarted = "workout_started"
    case workoutCompleted = "workout_completed"
    case setLogged = "set_logged"
    case foodLogged = "food_logged"
    case aiFoodScan = "ai_food_scan"
    case aiFoodScanCorrected = "ai_food_scan_corrected"
    case aiRecommendationViewed = "ai_recommendation_viewed"
    case nutritionCheckInViewed = "nutrition_checkin_viewed"
    case nutritionCheckInApplied = "nutrition_checkin_applied"
    case paywallViewed = "paywall_viewed"
    case trialStarted = "trial_started"
    case subscriptionStarted = "subscription_started"
    case subscriptionCancelled = "subscription_cancelled"
    case appOpened = "app_opened"
}

public enum AnalyticsValue: Codable, Hashable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(String(value.prefix(200)))
        case .number(let value): try container.encode(value.isFinite ? value : 0)
        case .bool(let value): try container.encode(value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? container.decode(Double.self) { self = .number(number) }
        else { self = .string(try container.decode(String.self)) }
    }
}

/// One event. Properties describe behaviour, never content: no food names,
/// no free text, no health values beyond coarse counts.
public struct AnalyticsEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: AnalyticsEventName
    public var occurredAt: Date
    public var properties: [String: AnalyticsValue]

    public init(id: UUID = UUID(), name: AnalyticsEventName, occurredAt: Date = Date(), properties: [String: AnalyticsValue] = [:]) {
        self.id = id
        self.name = name
        self.occurredAt = occurredAt
        self.properties = properties
    }

    enum CodingKeys: String, CodingKey { case id, name, occurredAt = "occurred_at", properties }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(name, forKey: .name)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try container.encode(formatter.string(from: occurredAt), forKey: .occurredAt)
        try container.encode(properties, forKey: .properties)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID(uuidString: try container.decode(String.self, forKey: .id)) ?? UUID()
        name = try container.decode(AnalyticsEventName.self, forKey: .name)
        let raw = try container.decode(String.self, forKey: .occurredAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        occurredAt = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) ?? Date()
        properties = try container.decode([String: AnalyticsValue].self, forKey: .properties)
    }
}

/// Buffers events and uploads them in batches. Events survive app restarts
/// through `persist`, uploads are idempotent (client ids), and nothing is
/// queued or sent while the user has opted out or isn't signed in.
public actor EventQueue {
    public static let maxQueued = 500
    public static let batchSize = 50

    private var pending: [AnalyticsEvent]
    private var isFlushing = false
    private let upload: @Sendable ([AnalyticsEvent]) async throws -> Void
    private let persist: @Sendable ([AnalyticsEvent]) -> Void
    private let isEnabled: @Sendable () -> Bool

    public init(restored: [AnalyticsEvent] = [],
                isEnabled: @escaping @Sendable () -> Bool,
                upload: @escaping @Sendable ([AnalyticsEvent]) async throws -> Void,
                persist: @escaping @Sendable ([AnalyticsEvent]) -> Void = { _ in }) {
        pending = Array(restored.suffix(Self.maxQueued))
        self.isEnabled = isEnabled
        self.upload = upload
        self.persist = persist
    }

    public var count: Int { pending.count }

    public func track(_ event: AnalyticsEvent) {
        guard isEnabled() else { return }
        pending.append(event)
        // Bounded: on a long offline stretch the oldest events go first.
        if pending.count > Self.maxQueued { pending.removeFirst(pending.count - Self.maxQueued) }
        persist(pending)
    }

    /// Uploads everything queued, batch by batch. Stops at the first failure
    /// and keeps the rest for next time.
    public func flush() async {
        guard !isFlushing else { return }
        guard isEnabled() else {
            clear()
            return
        }
        isFlushing = true
        defer { isFlushing = false }
        while !pending.isEmpty {
            let batch = Array(pending.prefix(Self.batchSize))
            do {
                try await upload(batch)
            } catch {
                return
            }
            let sent = Set(batch.map(\.id))
            pending.removeAll { sent.contains($0.id) }
            persist(pending)
        }
    }

    /// Drops everything queued (used when the user opts out).
    public func clear() {
        pending.removeAll()
        persist(pending)
    }
}
