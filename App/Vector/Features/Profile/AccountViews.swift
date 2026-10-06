import AuthenticationServices
import SwiftUI
import VectorCore

/// Sign in with Apple with a per-attempt nonce, so the identity token can't be replayed.
struct AccountSignInButton: View {
    var onSignedIn: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce = AppModel.makeNonce()

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            nonce = AppModel.makeNonce()
            request.requestedScopes = []
            request.nonce = nonce.hashed
        } onCompletion: { result in
            let raw = nonce.raw
            Task {
                await model.completeSignIn(result, nonce: raw)
                if model.isSignedIn { onSignedIn() }
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: Size.buttonHeight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}

/// Account status, privacy controls and deletion, shown in Profile.
struct AccountSection: View {
    @Environment(AppModel.self) private var model
    @State private var analytics = AnalyticsPreference.isEnabled
    @State private var confirmsDelete = false
    @State private var isDeleting = false
    @State private var deleteFailed = false
    @State private var offersLocalErase = false

    var body: some View {
        Section {
            if model.isSignedIn {
                LabeledContent("Signed in with Apple") {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(VColor.success)
                }
                if let allowance = model.scanAllowance {
                    LabeledContent("AI meal scans", value: allowanceText(allowance))
                }
                Button("Sign Out") { Task { await model.signOut() } }
            } else {
                AccountSignInButton()
                    .listRowInsets(EdgeInsets(top: Space.xs, leading: Space.md, bottom: Space.xs, trailing: Space.md))
            }
            Toggle("Share usage analytics", isOn: $analytics)
                .onChange(of: analytics) { _, enabled in model.setAnalyticsEnabled(enabled) }
            if model.isSignedIn {
                Button(role: .destructive) {
                    confirmsDelete = true
                } label: {
                    if isDeleting { ProgressView() } else { Text("Delete Account") }
                }
                .disabled(isDeleting)
            }
        } header: {
            Text("Account")
        } footer: {
            Text(model.isSignedIn
                 ? "Your workouts and food logs stay on your devices and iCloud. Your account holds your subscription and AI scan usage. Analytics are usage events linked to your account (never what you eat or lift), and you can turn them off here."
                 : "Optional. An account is needed for AI meal scans and keeps your Pro subscription linked. Apple shares only a private account identifier, not your name or email.")
        }
        .confirmationDialog("Delete your account?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) {
                isDeleting = true
                Task {
                    let deleted = await model.deleteAccount()
                    isDeleting = false
                    if deleted { offersLocalErase = true } else { deleteFailed = true }
                }
            }
        } message: {
            Text("This permanently deletes your account, scan history and analytics from our servers. An active subscription must be cancelled separately in Settings › Apple ID › Subscriptions.")
        }
        .alert("Couldn't delete your account", isPresented: $deleteFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again. Nothing was deleted.")
        }
        .confirmationDialog("Account deleted. Also erase this device's data?", isPresented: $offersLocalErase, titleVisibility: .visible) {
            Button("Erase Workouts and Food Logs", role: .destructive) { model.resetAll() }
            Button("Keep on This Device", role: .cancel) {}
        } message: {
            Text("Your logs are stored on this device and in your iCloud, not on our servers.")
        }
    }

    private func allowanceText(_ allowance: ScanAllowance) -> String {
        allowance.window == "day"
            ? "\(allowance.remaining) of \(allowance.limit) left today"
            : "\(allowance.remaining) of \(allowance.limit) left this week"
    }
}
