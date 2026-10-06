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
        // The backend is optional: without it the app works fully, minus AI
        // meal scans, server-verified Pro and analytics upload.
        var api: APIClient?
        var events: EventQueue?
        var recognizer: MealRecognizing?
        if let baseURL = AppConfig.apiBaseURL, !uiTesting {
            let client = APIClient(baseURL: baseURL, tokens: KeychainTokenStore())
            api = client
            recognizer = RemoteMealRecognizer(api: client)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            events = EventQueue(
                restored: EventQueueFile.load(),
                // Queued while signed out (bounded), uploaded once signed in.
                isEnabled: { AnalyticsPreference.isEnabled },
                upload: { try await client.send(events: $0, appVersion: version) },
                persist: { EventQueueFile.save($0) }
            )
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
            api: api,
            events: events,
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
                    purchases.accountToken = { [weak model] in model?.purchaseAccountToken }
                    purchases.onVerifiedTransaction = { [weak model] jws in await model?.submitTransaction(jws) }
                    purchases.onPurchaseEvent = { [weak model] event, product in model?.track(event, ["product": .string(product)]) }
                    model.syncPurchasesToServer = { [purchases] in await purchases.syncEntitlementsToServer() }
                    model.track(.appOpened)
                    await purchases.load()
                    await model.refreshAccount()
                    if model.isSignedIn { await purchases.syncEntitlementsToServer() }
                }
                .onOpenURL { url in handle(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.flush()
                model.flushEvents()
            case .active:
                Task { await model.refreshAccount() }
            default:
                break
            }
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
