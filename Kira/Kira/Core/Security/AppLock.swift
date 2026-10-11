import Foundation
import LocalAuthentication
import SwiftUI
import Observation

/// Face ID / Touch ID / passcode app lock.
///
/// The lock is a privacy screen in front of data that is already encrypted at rest by Data
/// Protection; it protects against someone using an unlocked phone. Falls back to the device
/// passcode (`.deviceOwnerAuthentication`) so users are never locked out if biometrics fail.
@MainActor
@Observable
final class AppLock {
    private(set) var isLocked: Bool
    private(set) var lastError: String?
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }
    /// Re-lock after this many seconds in the background.
    var gracePeriod: TimeInterval = 30

    private var backgroundedAt: Date?
    private static let enabledKey = "kira.appLock.enabled"

    init() {
        let enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        isEnabled = enabled
        isLocked = enabled
    }

    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func unlock() async {
        guard isLocked else { return }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your financial data")
            if success { isLocked = false; lastError = nil }
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            lastError = nil
        } catch {
            lastError = "Couldn’t verify it’s you. Try again."
        }
    }

    /// Enabling requires a successful authentication first, so users can't lock themselves out.
    func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else { isEnabled = false; isLocked = false; return true }
        let context = LAContext()
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Turn on app lock")
            if ok { isEnabled = true }
            return ok
        } catch {
            return false
        }
    }

    func handle(scenePhase: ScenePhase) {
        switch scenePhase {
        case .background:
            backgroundedAt = Date()
        case .active:
            if isEnabled, let backgroundedAt, Date().timeIntervalSince(backgroundedAt) > gracePeriod {
                isLocked = true
            }
            backgroundedAt = nil
        default:
            break
        }
    }
}

/// Hides financial content in the app switcher snapshot and while locked.
struct PrivacyShield: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let lock: AppLock

    func body(content: Content) -> some View {
        ZStack {
            content
                .blur(radius: shouldCover ? 24 : 0)
                .allowsHitTesting(!lock.isLocked)
                .accessibilityHidden(shouldCover)
            if shouldCover {
                LockScreen(lock: lock, showsUnlock: lock.isLocked)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shouldCover)
    }

    private var shouldCover: Bool { lock.isLocked || scenePhase != .active }
}

private struct LockScreen: View {
    let lock: AppLock
    let showsUnlock: Bool

    var body: some View {
        VStack(spacing: KiraSpacing.l) {
            Image(systemName: "lock.fill").font(.system(size: 36)).foregroundStyle(KiraColor.accent)
            Text("Kira is locked").font(.title3.weight(.semibold)).foregroundStyle(KiraColor.textPrimary)
            if showsUnlock {
                Button("Unlock with \(lock.biometryName)") { Task { await lock.unlock() } }
                    .buttonStyle(KiraPrimaryButtonStyle())
                if let error = lock.lastError {
                    Text(error).font(.footnote).foregroundStyle(KiraColor.error)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KiraColor.background.ignoresSafeArea())
        .task { if showsUnlock { await lock.unlock() } }
    }
}
