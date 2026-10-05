import SwiftUI
import VectorCore

@main
struct VectorApp: App {
    @State private var model: AppModel
    @State private var purchases = PurchaseService()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let store: DataStore = (try? JSONFileStore.applicationSupport()) ?? InMemoryStore()
        let recognizer: MealRecognizing
        if let endpoint = Bundle.main.object(forInfoDictionaryKey: "VectorMealScanEndpoint") as? String,
           let url = URL(string: endpoint), !endpoint.isEmpty {
            recognizer = RemoteMealRecognizer(endpoint: url)
        } else {
            // No backend configured (local builds, previews): use the on-device demo recognizer.
            recognizer = DemoMealRecognizer()
        }
        let arguments = ProcessInfo.processInfo.arguments
        let model = AppModel(
            store: arguments.contains("-uiTesting") ? InMemoryStore() : store,
            recognizer: recognizer,
            notifications: NotificationScheduler(),
            liveActivity: LiveActivityController(),
            health: HealthKitService()
        )
        if arguments.contains("-sampleData") { model.loadSampleData() }
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
