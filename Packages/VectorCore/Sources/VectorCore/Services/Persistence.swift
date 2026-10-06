import Foundation

/// A next-session target the athlete accepted or adjusted. Applied when
/// the next workout containing the exercise starts, then cleared.
public struct TargetOverride: Codable, Hashable, Sendable {
    public var weight: Double
    public var reps: Int

    public init(weight: Double, reps: Int) {
        self.weight = weight
        self.reps = reps
    }
}

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
    /// Optional so documents written before this field existed still decode.
    public var targetOverrides: [String: TargetOverride]?
    /// Tombstones ("kind:id") so a deletion on one device isn't undone by a sync.
    public var deletedIDs: Set<String>?
    /// When this copy last changed; decides which device's settings win a merge.
    public var modifiedAt: Date?
    /// User-created exercises (ids prefixed `custom-`).
    public var customExercises: [Exercise]?
    public var favoriteExerciseIDs: Set<String>?
    /// Foods starred for one-tap logging. Stored whole because Open Food Facts items aren't bundled.
    public var favoriteFoods: [FoodItem]?
    /// Rest time the athlete last chose for each exercise, in seconds.
    public var restPreferences: [String: Int]?
    /// Weekly adaptive-nutrition check-ins, oldest first.
    public var checkIns: [NutritionCheckIn]?
    /// Tape measurements, oldest first. Synced like weigh-ins.
    public var bodyMeasurements: [BodyMeasurementEntry]?
    /// Progress photo metadata. Device-local: never merged from or written to
    /// iCloud (`SyncMerge`), and the images themselves stay in the app container.
    public var progressPhotos: [ProgressPhoto]?
    /// Every weekly coaching decision (applied, kept or rejected), oldest first.
    public var coachDecisions: [CoachDecision]?
    /// The user's own discomfort notes. Never sent to the backend or the AI.
    public var discomfortNotes: [DiscomfortNote]?

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
        tier: SubscriptionTier = .free,
        targetOverrides: [String: TargetOverride]? = nil,
        deletedIDs: Set<String>? = nil,
        modifiedAt: Date? = nil,
        customExercises: [Exercise]? = nil,
        favoriteExerciseIDs: Set<String>? = nil,
        favoriteFoods: [FoodItem]? = nil,
        restPreferences: [String: Int]? = nil,
        checkIns: [NutritionCheckIn]? = nil,
        bodyMeasurements: [BodyMeasurementEntry]? = nil,
        progressPhotos: [ProgressPhoto]? = nil,
        coachDecisions: [CoachDecision]? = nil,
        discomfortNotes: [DiscomfortNote]? = nil
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
        self.targetOverrides = targetOverrides
        self.deletedIDs = deletedIDs
        self.modifiedAt = modifiedAt
        self.customExercises = customExercises
        self.favoriteExerciseIDs = favoriteExerciseIDs
        self.favoriteFoods = favoriteFoods
        self.restPreferences = restPreferences
        self.checkIns = checkIns
        self.bodyMeasurements = bodyMeasurements
        self.progressPhotos = progressPhotos
        self.coachDecisions = coachDecisions
        self.discomfortNotes = discomfortNotes
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

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
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
