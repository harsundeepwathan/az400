import Foundation

/// Everything the app persists, as one versioned document. At this data
/// size (years of training fit in a few MB) a single atomic JSON write is
/// simpler and more robust than a database, and trivially exportable.
public struct AppData: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var profile: UserProfile?
    public var program: TrainingProgram?
    public var customTemplates: [WorkoutTemplate]
    public var sessions: [WorkoutSession]
    public var activeWorkout: ActiveWorkout?
    public var restTimer: RestTimer?
    public var foodEntries: [FoodEntry]
    public var savedMeals: [SavedMeal]
    public var bodyWeights: [BodyWeightEntry]
    public var scanDates: [Date]
    public var dismissedInsightIDs: Set<String>
    public var lastUpgradeMoment: Date?
    public var tier: SubscriptionTier

    public init(
        schemaVersion: Int = AppData.currentSchemaVersion,
        profile: UserProfile? = nil,
        program: TrainingProgram? = nil,
        customTemplates: [WorkoutTemplate] = [],
        sessions: [WorkoutSession] = [],
        activeWorkout: ActiveWorkout? = nil,
        restTimer: RestTimer? = nil,
        foodEntries: [FoodEntry] = [],
        savedMeals: [SavedMeal] = [],
        bodyWeights: [BodyWeightEntry] = [],
        scanDates: [Date] = [],
        dismissedInsightIDs: Set<String> = [],
        lastUpgradeMoment: Date? = nil,
        tier: SubscriptionTier = .free
    ) {
        self.schemaVersion = schemaVersion
        self.profile = profile
        self.program = program
        self.customTemplates = customTemplates
        self.sessions = sessions
        self.activeWorkout = activeWorkout
        self.restTimer = restTimer
        self.foodEntries = foodEntries
        self.savedMeals = savedMeals
        self.bodyWeights = bodyWeights
        self.scanDates = scanDates
        self.dismissedInsightIDs = dismissedInsightIDs
        self.lastUpgradeMoment = lastUpgradeMoment
        self.tier = tier
    }

    public var hasCompletedOnboarding: Bool { profile != nil }
}

public protocol DataStore: Sendable {
    func load() throws -> AppData?
    func save(_ data: AppData) throws
}

public final class JSONFileStore: DataStore, @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public static func applicationSupport(fileName: String = "vector-data.json") throws -> JSONFileStore {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
        return JSONFileStore(url: directory.appendingPathComponent(fileName))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func load() throws -> AppData? {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(AppData.self, from: data)
    }

    public func save(_ data: AppData) throws {
        lock.lock(); defer { lock.unlock() }
        let encoded = try Self.encoder.encode(data)
        try encoded.write(to: url, options: [.atomic])
    }
}

public final class InMemoryStore: DataStore, @unchecked Sendable {
    private var data: AppData?
    private let lock = NSLock()

    public init(_ data: AppData? = nil) {
        self.data = data
    }

    public func load() throws -> AppData? {
        lock.lock(); defer { lock.unlock() }
        return data
    }

    public func save(_ data: AppData) throws {
        lock.lock(); defer { lock.unlock() }
        self.data = data
    }
}
