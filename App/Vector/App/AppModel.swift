import Foundation
import Observation
import SwiftUI
import VectorCore
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Single source of truth for app state. Views read derived values and call
/// intent methods; all domain rules live in VectorCore engines, and all
/// platform effects (notifications, Live Activities, Health) are injected.
@Observable
@MainActor
final class AppModel {
    // MARK: State

    private(set) var data: AppData {
        didSet {
            sessionsCache = nil
            nutritionCache = [:]
            recentExercisesCache = nil
            reviewCache = nil
            if oldValue.customExercises != data.customExercises { rebuildCatalog() }
        }
    }
    var selectedTab: AppTab = .today
    var sheet: RootSheet?
    var cover: RootCover?
    var toast: ToastMessage?
    /// Bumped on every completed set; views attach haptics/animation to it.
    private(set) var lastCompletion: SetCompletion?
    private(set) var lastSummary: WorkoutSummary?
    /// Server account; nil when signed out or no backend is configured.
    private(set) var account: Account?
    /// The server's count of AI scans left. Preferred over the local estimate.
    private(set) var scanAllowance: ScanAllowance?
    /// Cached derived values, recomputed after each mutation.
    private(set) var insights: [CoachInsight] = []
    private(set) var recommendations: [ProgressionRecommendation] = [] {
        didSet { reviewCache = nil }
    }
    private(set) var isComputingInsights = false
    /// Created on first use and kept (see `photoStore`); not view state.
    @ObservationIgnored var photoStoreCache: ProgressPhotoStore?

    // MARK: Dependencies

    /// Built-in library plus the user's custom exercises.
    private(set) var catalog: ExerciseCatalog
    @ObservationIgnored private let baseCatalog: ExerciseCatalog
    let foods: FoodDatabase
    /// Nil when no backend is configured; the scanner then says so
    /// instead of returning made-up results.
    let recognizer: MealRecognizing?
    /// Open Food Facts (or any remote catalogue). Nil in previews and tests.
    let remoteFoods: RemoteFoodSearching?
    @ObservationIgnored let sync: CloudSync?
    /// `backend/api`. Nil when no API base URL is configured.
    @ObservationIgnored let api: APIClient?
    @ObservationIgnored let events: EventQueue?
    /// Set by the app: sends current StoreKit entitlements to the server.
    @ObservationIgnored var syncPurchasesToServer: (() async -> Void)?
    /// Called after every committed change (the Watch bridge listens here).
    @ObservationIgnored var onCommit: ((AppData) -> Void)?
    /// Last time this device merged with iCloud; nil when sync is off.
    private(set) var lastSyncedAt: Date?
    let calendar: Calendar
    @ObservationIgnored let store: DataStore
    @ObservationIgnored let notifications: NotificationScheduler?
    @ObservationIgnored let liveActivity: LiveActivityController?
    @ObservationIgnored let health: HealthSyncing?
    @ObservationIgnored var now: () -> Date
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var insightTask: Task<Void, Never>?
    // Derived-data caches, cleared whenever `data` changes. Getters still read
    // `data` first so SwiftUI observation tracks the dependency.
    @ObservationIgnored private var sessionsCache: (day: Date, value: [WorkoutSession])?
    @ObservationIgnored private var nutritionCache: [Date: DailyNutrition] = [:]
    @ObservationIgnored private var recentExercisesCache: [String]?
    @ObservationIgnored var reviewCache: (day: Date, review: WeeklyReview, today: TodayCoaching)?

    private(set) var analytics: AnalyticsEngine
    let nutritionEngine: NutritionEngine
    let progression = ProgressionEngine()
    private(set) var insightEngine: InsightEngine
    private(set) var substitutions: ExerciseSubstitutionEngine
    let policy: EntitlementPolicy

    init(
        store: DataStore,
        recognizer: MealRecognizing?,
        remoteFoods: RemoteFoodSearching? = nil,
        sync: CloudSync? = nil,
        api: APIClient? = nil,
        events: EventQueue? = nil,
        catalog: ExerciseCatalog = .standard,
        foods: FoodDatabase = FoodDatabase(),
        calendar: Calendar = .current,
        notifications: NotificationScheduler? = nil,
        liveActivity: LiveActivityController? = nil,
        health: HealthSyncing? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.recognizer = recognizer
        self.remoteFoods = remoteFoods
        self.sync = sync
        self.api = api
        self.events = events
        self.catalog = catalog
        self.baseCatalog = catalog
        self.foods = foods
        self.calendar = calendar
        self.notifications = notifications
        self.liveActivity = liveActivity
        self.health = health
        self.now = now
        analytics = AnalyticsEngine(catalog: catalog, calendar: calendar)
        nutritionEngine = NutritionEngine(calendar: calendar)
        insightEngine = InsightEngine(catalog: catalog, calendar: calendar)
        substitutions = ExerciseSubstitutionEngine(catalog: catalog)
        policy = EntitlementPolicy(calendar: calendar)
        data = (try? store.load()) ?? AppData()
        rebuildCatalog()
        recomputeInsights(immediately: true)
        if data.activeWorkout != nil { cover = .workout }
    }

    #if DEBUG
    /// In-memory model populated with realistic sample data, for previews.
    static func preview(pro: Bool = false, empty: Bool = false) -> AppModel {
        var data = empty ? AppData(profile: SampleData.appData().profile, program: SampleData.appData().program) : SampleData.appData()
        data.tier = pro ? .pro : .free
        return AppModel(store: InMemoryStore(data), recognizer: DemoMealRecognizer(latency: .milliseconds(1500)))
    }
    #endif

    private func rebuildCatalog() {
        catalog = baseCatalog.adding(data.customExercises ?? [])
        analytics = AnalyticsEngine(catalog: catalog, calendar: calendar)
        insightEngine = InsightEngine(catalog: catalog, calendar: calendar)
        substitutions = ExerciseSubstitutionEngine(catalog: catalog)
    }

    // MARK: Persistence

    /// Every intent funnels through here: mutate, recompute, persist.
    private func commit(_ mutate: (inout AppData) -> Void, refreshInsights: Bool = true) {
        mutate(&data)
        data.modifiedAt = now()
        if refreshInsights { recomputeInsights() }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = data
        let store = store
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            try? store.save(snapshot)
        }
        sync?.push(snapshot)
        onCommit?(snapshot)
        writeWidgetSnapshot()
    }

    /// Saves immediately (used when the app moves to the background).
    func flush() {
        saveTask?.cancel()
        try? store.save(data)
    }

    private func writeWidgetSnapshot() {
        guard let profile = data.profile else { return }
        let next = nextWorkout
        let today = nutrition(on: now())
        WidgetSnapshot(
            nextWorkoutName: next?.name,
            nextWorkoutDetail: next.map { "\($0.exercises.count) exercises · ~\($0.estimatedMinutes(catalog: catalog)) min" },
            caloriesConsumed: today.consumed.calories,
            caloriesTarget: profile.targets.calories,
            proteinConsumed: today.consumed.protein,
            proteinTarget: profile.targets.protein,
            updatedAt: now()
        ).save()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Insights touch the whole history, so they're computed off the main
    /// actor and the UI shows a skeleton until they land.
    private func recomputeInsights(immediately: Bool = false) {
        guard let profile = data.profile else {
            insights = []
            recommendations = []
            return
        }
        let context = CoachContext(sessions: data.sessions, foodEntries: data.foodEntries, bodyWeights: data.bodyWeights,
                                   program: data.program, profile: profile, now: now())
        let engine = insightEngine
        if immediately {
            insights = engine.insights(context)
            recommendations = engine.programRecommendations(context)
            return
        }
        insightTask?.cancel()
        isComputingInsights = true
        insightTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                (engine.insights(context), engine.programRecommendations(context))
            }.value
            guard !Task.isCancelled, let self else { return }
            withAnimation(Motion.smooth) {
                self.insights = result.0
                self.recommendations = result.1
                self.isComputingInsights = false
            }
        }
    }

    // MARK: Derived: profile & tier

    var profile: UserProfile? { data.profile }
    var unit: WeightUnit { data.profile?.unit ?? .kilograms }
    var tier: SubscriptionTier { data.tier }
    var isPro: Bool { data.tier == .pro }
    var hasOnboarded: Bool { data.hasCompletedOnboarding }
    var firstName: String {
        let name = data.profile?.name.split(separator: " ").first.map(String.init) ?? ""
        return name.isEmpty ? "athlete" : name
    }

    func presentPaywall(_ trigger: PaywallTrigger) {
        sheet = .paywall(trigger)
        track(.paywallViewed, ["trigger": .string(trigger.rawValue)])
    }

    func setTier(_ tier: SubscriptionTier) {
        guard tier != data.tier else { return }
        commit({ $0.tier = tier }, refreshInsights: false)
    }

    func showToast(_ symbol: String, _ title: String, subtitle: String? = nil) {
        withAnimation(Motion.snappy) { toast = ToastMessage(symbol: symbol, title: title, subtitle: subtitle) }
    }

    // MARK: Derived: training

    var program: TrainingProgram? { data.program }
    var nextWorkout: WorkoutTemplate? { data.program?.nextWorkout }
    var customTemplates: [WorkoutTemplate] { data.customTemplates }
    var activeWorkout: ActiveWorkout? { data.activeWorkout }
    var restTimer: RestTimer? { data.restTimer }

    /// Finished sessions, newest first, limited to the free history window.
    var sessions: [WorkoutSession] {
        let all = data.sessions
        let day = calendar.startOfDay(for: now())
        if let sessionsCache, sessionsCache.day == day { return sessionsCache.value }
        let cutoff = policy.historyCutoff(tier: data.tier, now: now())
        let value = all
            .filter { $0.isFinished && (cutoff.map { cutoff in $0.startedAt >= cutoff } ?? true) }
            .sorted { $0.startedAt > $1.startedAt }
        sessionsCache = (day, value)
        return value
    }

    /// Exercises trained most recently, for the picker.
    var recentExerciseIDs: [String] {
        let all = data.sessions
        if let recentExercisesCache { return recentExercisesCache }
        let value = analytics.recentExerciseIDs(all, limit: 12).filter { catalog[$0] != nil }
        recentExercisesCache = value
        return value
    }

    var hasHiddenHistory: Bool {
        guard let cutoff = policy.historyCutoff(tier: data.tier, now: now()) else { return false }
        return data.sessions.contains { $0.startedAt < cutoff }
    }

    func lastSession(for template: WorkoutTemplate) -> WorkoutSession? {
        data.sessions.filter { $0.isFinished && $0.templateID == template.id }.max { $0.startedAt < $1.startedAt }
    }

    func history(for exerciseID: String) -> [ExercisePerformance] {
        progression.history(for: exerciseID, in: sessions)
    }

    func recommendation(for exerciseID: String, repRange: RepRange = RepRange(8, 12), sets: Int = 3) -> ProgressionRecommendation? {
        guard let exercise = catalog[exerciseID] else { return nil }
        if let cached = recommendations.first(where: { $0.exerciseID == exerciseID }) { return cached }
        return progression.recommend(for: exercise, repRange: repRange, sets: sets, history: history(for: exerciseID), unit: unit)
    }

    var progressionOpportunities: [ProgressionRecommendation] {
        recommendations.filter { $0.action == .increaseLoad }
    }

    var shouldShowUpgradeMoment: Bool {
        policy.shouldShowUpgradeMoment(tier: data.tier, finishedWorkouts: data.sessions.count,
                                       progressionOpportunities: progressionOpportunities.count,
                                       isWorkoutActive: data.activeWorkout != nil,
                                       lastShown: data.lastUpgradeMoment, now: now())
    }

    func dismissUpgradeMoment() {
        commit({ $0.lastUpgradeMoment = now() }, refreshInsights: false)
    }

    var visibleInsights: [CoachInsight] {
        insights.filter { !data.dismissedInsightIDs.contains($0.id) }
    }

    /// Today's headline insight: the best one the user can fully read.
    var dailyInsight: CoachInsight? {
        visibleInsights.first { isPro || !$0.requiresPro }
    }

    func dismiss(_ insight: CoachInsight) {
        commit({ $0.dismissedInsightIDs.insert(insight.id) }, refreshInsights: false)
    }

    func handle(_ action: CoachInsight.Action) {
        switch action {
        case .startWorkout:
            if let next = nextWorkout { startWorkout(next) }
        case .openExercise(let id):
            sheet = .exercise(id)
        case .logFood:
            selectedTab = .nutrition
            sheet = .foodSearch(MealType.suggested(forHour: calendar.component(.hour, from: now())))
        case .reviewProgressions:
            sheet = .recommendations
        case .viewProgress, .viewMuscleBalance:
            selectedTab = .progress
        }
    }

    // MARK: Derived: nutrition

    func nutrition(on day: Date) -> DailyNutrition {
        let entries = data.foodEntries
        let key = calendar.startOfDay(for: day)
        if let cached = nutritionCache[key] { return cached }
        let value = nutritionEngine.daily(entries, on: day,
                                          targets: data.profile?.targets ?? NutritionTargets(calories: 2000, protein: 120, carbs: 220, fat: 65))
        nutritionCache[key] = value
        return value
    }

    func entries(on day: Date, meal: MealType) -> [FoodEntry] {
        nutritionEngine.entries(data.foodEntries, on: day).filter { $0.meal == meal }.sorted { $0.date < $1.date }
    }

    var recentFoods: [FoodEntry] { nutritionEngine.recentFoods(data.foodEntries) }
    var savedMeals: [SavedMeal] { data.savedMeals }

    var proteinStreak: Int {
        guard let targets = data.profile?.targets else { return 0 }
        return nutritionEngine.proteinStreak(data.foodEntries, now: now(), targets: targets)
    }

    /// Free scans left, for display. Nil means "don't show a count" (Pro).
    var scansRemaining: Int? {
        if let scanAllowance { return scanAllowance.tier == .free ? scanAllowance.remaining : nil }
        return policy.scansRemaining(tier: data.tier, scanDates: data.scanDates, now: now())
    }

    /// The server enforces the real limit; this only decides whether to offer the camera.
    var canScan: Bool {
        if let scanAllowance { return scanAllowance.remaining > 0 }
        return policy.canScan(tier: data.tier, scanDates: data.scanDates, now: now())
    }

    var bodyWeights: [BodyWeightEntry] { data.bodyWeights.sorted { $0.date < $1.date } }
    var latestBodyWeight: BodyWeightEntry? { data.bodyWeights.max { $0.date < $1.date } }

    // MARK: Intents: nutrition

    func log(_ entries: [FoodEntry], toast: Bool = true) {
        guard !entries.isEmpty else { return }
        commit { $0.foodEntries.append(contentsOf: entries) }
        track(.foodLogged, ["source": .string(entries[0].source.rawValue), "items": .number(Double(entries.count)),
                            "meal": .string(entries[0].meal.rawValue)])
        if toast {
            let calories = entries.reduce(0) { $0 + $1.macros.calories }
            showToast("checkmark.circle.fill", "Added to \(entries[0].meal.displayName)", subtitle: "\(Format.integer(calories)) kcal")
        }
    }

    /// Logs an AI-scanned meal and reports how the estimate was corrected
    /// (counts and calories only, no food names or photo) to measure accuracy.
    func logScannedMeal(_ entries: [FoodEntry], correction: ScanCorrection, scanID: String?) {
        log(entries)
        track(.aiFoodScanCorrected, [
            "corrected": .bool(correction.wasCorrected),
            "renamed": .number(Double(correction.renamed)),
            "removed": .number(Double(correction.removed)),
            "added": .number(Double(correction.added)),
            "portions_changed": .number(Double(correction.portionsChanged)),
            "macros_edited": .number(Double(correction.macrosEdited)),
            "calorie_error_pct": .number((correction.calorieError * 100).rounded())
        ])
        if let scanID, let api {
            Task { try? await api.submitCorrection(scanID: scanID, correction) }
        }
    }

    // MARK: Favourite foods

    var favoriteFoods: [FoodItem] { data.favoriteFoods ?? [] }

    func isFavorite(food: FoodItem) -> Bool { data.favoriteFoods?.contains { $0.id == food.id } ?? false }

    func toggleFavorite(food: FoodItem) {
        commit({ data in
            var foods = data.favoriteFoods ?? []
            if let index = foods.firstIndex(where: { $0.id == food.id }) {
                foods.remove(at: index)
            } else {
                foods.insert(food, at: 0)
            }
            data.favoriteFoods = foods
        }, refreshInsights: false)
        Haptics.light()
    }

    func update(_ entry: FoodEntry) {
        commit { data in
            if let index = data.foodEntries.firstIndex(where: { $0.id == entry.id }) { data.foodEntries[index] = entry }
        }
    }

    func delete(_ entry: FoodEntry) {
        commit { data in
            data.foodEntries.removeAll { $0.id == entry.id }
            data.deletedIDs = (data.deletedIDs ?? []).union([Tombstone.food(entry.id)])
        }
    }

    func copyMeal(_ meal: MealType, from source: Date, to target: Date) {
        let offset = calendar.startOfDay(for: target).timeIntervalSince(calendar.startOfDay(for: source))
        let copies = entries(on: source, meal: meal).map {
            FoodEntry(date: $0.date.addingTimeInterval(offset), meal: meal, name: $0.name, foodID: $0.foodID,
                      grams: $0.grams, macros: $0.macros, source: $0.source)
        }
        log(copies)
    }

    func saveMeal(named name: String, entries: [FoodEntry]) {
        guard !entries.isEmpty else { return }
        commit({ $0.savedMeals.append(SavedMeal(name: name, items: entries)) }, refreshInsights: false)
        showToast("square.stack.fill", "Saved “\(name)”")
    }

    func deleteSavedMeal(_ meal: SavedMeal) {
        commit({ data in
            data.savedMeals.removeAll { $0.id == meal.id }
            data.deletedIDs = (data.deletedIDs ?? []).union([Tombstone.savedMeal(meal.id)])
        }, refreshInsights: false)
    }

    func recordScan(_ analysis: MealAnalysis) {
        commit({ $0.scanDates.append(now()) }, refreshInsights: false)
        if let allowance = analysis.allowance { scanAllowance = allowance }
        track(.aiFoodScan, ["items": .number(Double(analysis.items.count)), "result": "ok"])
    }

    func recordScanFailure(_ error: MealRecognitionError) {
        if error == .quotaExceeded, var allowance = scanAllowance {
            allowance.remaining = 0
            scanAllowance = allowance
        }
        if error == .signInRequired { account = nil }
        track(.aiFoodScan, ["result": .string(String(describing: error))])
    }

    func setAccount(_ account: Account?) { self.account = account }
    func setScanAllowance(_ allowance: ScanAllowance?) { scanAllowance = allowance }

    func logBodyWeight(_ kilograms: Double) {
        let entry = BodyWeightEntry(date: now(), kilograms: kilograms)
        commit { data in
            let replaced = data.bodyWeights.filter { self.calendar.isDate($0.date, inSameDayAs: entry.date) }
            data.deletedIDs = (data.deletedIDs ?? []).union(replaced.map { Tombstone.bodyWeight($0.id) })
            data.bodyWeights.removeAll { self.calendar.isDate($0.date, inSameDayAs: entry.date) }
            data.bodyWeights.append(entry)
            data.profile?.weightKg = kilograms
        }
        if let health { Task { try? await health.save(bodyWeight: entry) } }
    }

    // MARK: Intents: profile

    func completeOnboarding(with plan: GeneratedPlan) {
        commit { data in
            data.profile = plan.profile
            data.program = plan.program
            data.bodyWeights.append(BodyWeightEntry(date: now(), kilograms: plan.profile.weightKg))
        }
        selectedTab = .today
        track(.onboardingCompleted, ["goal": .string(plan.profile.goal.rawValue), "experience": .string(plan.profile.experience.rawValue),
                                     "days_per_week": .number(Double(plan.profile.daysPerWeek)), "equipment": .string(plan.profile.equipment.rawValue)])
    }

    func updateProfile(_ mutate: (inout UserProfile) -> Void) {
        commit { data in
            guard var profile = data.profile else { return }
            mutate(&profile)
            data.profile = profile
        }
    }

    func replaceProgram(_ program: TrainingProgram) {
        commit { $0.program = program }
        showToast("checkmark.circle.fill", "Program updated", subtitle: program.name)
    }

    #if DEBUG
    func loadSampleData() {
        let tier = data.tier
        var sample = SampleData.appData(now: now(), calendar: calendar)
        sample.tier = tier
        commit { $0 = sample }
    }
    #endif

    func resetAll() {
        liveActivity?.end()
        notifications?.cancelRest()
        let tier = data.tier
        // Tombstone everything so other devices delete it too instead of syncing it back.
        let tombstones = Tombstone.all(in: data).union(data.deletedIDs ?? [])
        commit { $0 = AppData(tier: tier, deletedIDs: tombstones) }
        // Photo files live outside AppData; delete them now, not on the next visit.
        removeOrphanedPhotoFiles()
        // So is the digest behind the last coach summary.
        coachSummaryArchive?.clear()
        cover = nil
        sheet = nil
    }

    func exportData() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vector-export.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(data) else { return nil }
        try? encoded.write(to: url)
        return url
    }

    // MARK: Sync

    /// Merges a copy that arrived from iCloud. Called on launch and whenever
    /// another device writes.
    func mergeRemote(_ remote: AppData) {
        let merged = SyncMerge.merge(local: data, remote: remote)
        lastSyncedAt = now()
        guard merged != data else { return }
        let hadProfile = data.profile != nil
        data = merged
        recomputeInsights()
        try? store.save(data)
        writeWidgetSnapshot()
        if !hadProfile, data.profile != nil { selectedTab = .today }
    }

    func startSync() {
        guard let sync else { return }
        sync.start { [weak self] remote in
            Task { @MainActor in self?.mergeRemote(remote) }
        }
    }

    // MARK: Internal mutation access for extensions

    func mutate(_ change: (inout AppData) -> Void, refreshInsights: Bool = true) {
        commit(change, refreshInsights: refreshInsights)
    }

    func setLastCompletion(_ completion: SetCompletion?) { lastCompletion = completion }
    func setLastSummary(_ summary: WorkoutSummary?) { lastSummary = summary }
}
