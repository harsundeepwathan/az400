import SwiftUI
import SwiftData
import KiraCore

@main
struct KiraApp: App {
    @State private var environment = AppEnvironment.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment.store)
                .environment(environment.subscriptions)
                .environment(environment.lock)
                .modifier(PrivacyShield(lock: environment.lock))
                .tint(KiraColor.accent)
        }
        .onChange(of: scenePhase) { _, phase in
            environment.lock.handle(scenePhase: phase)
            if phase == .active {
                // Protected data is available again: bring in captures written while locked.
                environment.store.drainInbox()
            }
        }
    }
}

/// Dependency container. `live()` wires production services; UI tests launch with
/// `-uiTesting` to get an isolated in-memory store.
@MainActor
final class AppEnvironment {
    let store: FinanceStore
    let subscriptions: SubscriptionManager
    let lock: AppLock

    init(store: FinanceStore, subscriptions: SubscriptionManager, lock: AppLock) {
        self.store = store
        self.subscriptions = subscriptions
        self.lock = lock
    }

    static let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")

    static func live() -> AppEnvironment {
        let container: ModelContainer
        do {
            container = try PersistenceController.makeContainer(inMemory: isUITesting)
        } catch {
            // Never silently continue with an empty store that would later overwrite real data;
            // fall back to memory and surface the error to the user.
            container = try! PersistenceController.makeContainer(inMemory: true)
            let store = FinanceStore(repository: SwiftDataFinanceRepository(container: container))
            store.lastErrorMessage = "Your data couldn’t be opened (\(error.localizedDescription)). Changes made now won’t be saved."
            return AppEnvironment(store: store, subscriptions: SubscriptionManager(), lock: AppLock())
        }
        let inbox = isUITesting
            ? CaptureInbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent("KiraUITestInbox"))
            : CaptureInbox()
        let store = FinanceStore(repository: SwiftDataFinanceRepository(container: container), inbox: inbox)
        store.load()
        let subscriptions = SubscriptionManager()
        subscriptions.onTierChange = { [weak store] tier in store?.tier = tier }
        if isUITesting {
            store.tier = .premium
        } else {
            subscriptions.start()
        }
        SharedEnvironment.shared.store = store
        return AppEnvironment(store: store, subscriptions: subscriptions, lock: AppLock())
    }
}

/// Lets App Intents reach the live store when the app process is already running.
@MainActor
final class SharedEnvironment {
    static let shared = SharedEnvironment()
    weak var store: FinanceStore?
}
