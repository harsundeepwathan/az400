import SwiftUI
import VectorCore

@main
struct VectorApp: App {
    @State private var model: AppModel
    @State private var purchases = PurchaseService()
    @State private var watchBridge = PhoneWatchBridge()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Room for exercise demonstration photos so they load once and work offline afterwards.
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        let store: DataStore = (try? JSONFileStore.applicationSupport()) ?? InMemoryStore()
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
        let uiTesting = arguments.contains("-uiTesting")
        #else
        let uiTesting = false
        #endif
        var recognizer: MealRecognizing?
        if let endpoint = AppConfig.mealScanEndpoint {
            let key = Bundle.main.object(forInfoDictionaryKey: "VectorMealScanKey") as? String
            recognizer = RemoteMealRecognizer(endpoint: endpoint, appKey: key)
        }
        #if DEBUG
        // Debug builds without a backend use the offline recognizer so the review flow can be exercised.
        // Release builds never do: the scanner reports that it's unavailable instead.
        if recognizer == nil || uiTesting { recognizer = DemoMealRecognizer(latency: .milliseconds(uiTesting ? 300 : 2000)) }
        #endif
        let syncEnabled = UserDefaults.standard.object(forKey: CloudSyncPreference.key) as? Bool ?? true
        let model = AppModel(
            store: uiTesting ? InMemoryStore() : store,
            recognizer: recognizer,
            remoteFoods: uiTesting ? nil : OpenFoodFactsClient(),
            sync: uiTesting || !syncEnabled ? nil : ICloudDocumentSync(),
            notifications: NotificationScheduler(),
            liveActivity: LiveActivityController(),
            health: HealthKitService()
        )
        #if DEBUG
        if arguments.contains("-sampleData") { model.loadSampleData() }
        #endif
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(purchases)
                .tint(VColor.accentText)
                .task {
                    let model = model
                    model.startSync()
                    watchBridge.start(model: model)
                    DiagnosticsReporter.shared.start()
                    purchases.onTierChange = { [weak model] tier in model?.setTier(tier) }
                    await purchases.load()
                }
                .onOpenURL { url in handle(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.flush() }
        }
    }

    /// Deep links used by widgets and the Live Activity: vector://workout, vector://scan, vector://nutrition.
    private func handle(_ url: URL) {
        guard url.scheme == "vector" else { return }
        switch url.host {
        case "workout":
            if model.activeWorkout != nil { model.resumeWorkout() } else if let next = model.nextWorkout { model.startWorkout(next) }
        case "scan":
            model.cover = .scanner(MealType.suggested(forHour: Calendar.current.component(.hour, from: Date())))
        case "nutrition":
            model.selectedTab = .nutrition
        default:
            break
        }
    }
}
