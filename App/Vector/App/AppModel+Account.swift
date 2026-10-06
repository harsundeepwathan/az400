import AuthenticationServices
import CryptoKit
import Foundation
import VectorCore

/// Account, server entitlement and analytics. The app works fully without an
/// account; signing in is needed for AI meal scans (fair quotas) and
/// server-verified Pro.
extension AppModel {
    var isAccountAvailable: Bool { api != nil }
    var isSignedIn: Bool { account != nil || (api?.isSignedIn ?? false) }

    // MARK: Sign in with Apple

    /// A fresh random nonce. Apple gets its SHA-256; the server checks the raw value.
    static func makeNonce() -> (raw: String, hashed: String) {
        let raw = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let hashed = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return (raw, hashed)
    }

    func completeSignIn(_ result: Result<ASAuthorization, Error>, nonce: String) async {
        guard let api else { return }
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8) else {
                showToast("exclamationmark.triangle", "Sign in didn't complete")
                return
            }
            do {
                try await api.signInWithApple(identityToken: token, nonce: nonce)
                await refreshAccount()
                await syncPurchasesToServer?()
                showToast("person.crop.circle.badge.checkmark", "Signed in")
            } catch {
                showToast("wifi.slash", "Couldn't sign in", subtitle: "Check your connection and try again.")
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                showToast("exclamationmark.triangle", "Sign in didn't complete")
            }
        }
    }

    /// Reloads entitlement, scan allowance and analytics preference from the server.
    func refreshAccount() async {
        guard let api, api.isSignedIn else {
            setAccount(nil)
            return
        }
        do {
            let account = try await api.account()
            setAccount(account)
            setScanAllowance(account.scans)
        } catch APIError.signedOut {
            setAccount(nil)
        } catch {
            // Offline: keep what we had.
        }
    }

    func signOut() async {
        await api?.signOut()
        await events?.clear()
        coachSummaryArchive?.clear()
        setAccount(nil)
        setScanAllowance(nil)
    }

    /// Deletes the server account and its data. Local training and food logs
    /// are separate; Profile offers to erase them too.
    func deleteAccount() async -> Bool {
        guard let api else { return false }
        do {
            try await api.deleteAccount()
            await events?.clear()
            coachSummaryArchive?.clear()
            setAccount(nil)
            setScanAllowance(nil)
            return true
        } catch APIError.signedOut {
            setAccount(nil)
            return true
        } catch {
            return false
        }
    }

    // MARK: Purchases

    /// Sends a verified StoreKit transaction to the server so AI quotas
    /// follow the real subscription. Silent when signed out or offline;
    /// the next launch retries via current entitlements.
    func submitTransaction(_ signedTransaction: String) async {
        guard let api, api.isSignedIn else { return }
        if (try? await api.submitTransaction(signedTransaction)) != nil {
            await refreshAccount()
        }
    }

    /// The user id to stamp on purchases (`appAccountToken`), so a purchase is bound to this account.
    var purchaseAccountToken: UUID? { api?.userID.flatMap(UUID.init(uuidString:)) }

    // MARK: Analytics

    var analyticsEnabled: Bool { AnalyticsPreference.isEnabled }

    func setAnalyticsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: AnalyticsPreference.key)
        Task {
            if !enabled { await events?.clear() }
            try? await api?.setAnalyticsOptOut(!enabled)
        }
    }

    /// Records a product event. Never includes food names, notes or other free text.
    func track(_ name: AnalyticsEventName, _ properties: [String: AnalyticsValue] = [:]) {
        guard let events else { return }
        let event = AnalyticsEvent(name: name, occurredAt: now(), properties: properties)
        Task { await events.track(event) }
    }

    func flushEvents() {
        guard let events else { return }
        Task { await events.flush() }
    }
}
