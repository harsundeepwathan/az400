import AppIntents
import Foundation
import UIKit
import KiraCore

/// "Log Payment in Kira" — designed to be the action inside a Shortcuts personal automation
/// using the Wallet **Transaction** trigger ("When I tap any of these cards").
///
/// What this can and cannot do (see docs/FEASIBILITY.md):
/// - The Transaction trigger passes the Card or Pass, Merchant and Amount for in-store taps on
///   cards the user selects. It is not documented to fire for online / in-app Apple Pay.
/// - Values can arrive blank (reported by developers), so every parameter is optional and an
///   incomplete record is kept as *pending* with a review flag rather than dropped.
/// - A tap is an authorisation, not a settled payment, so the record is always `pending` until
///   confirmed by the user, a receipt, or a statement import.
struct LogPaymentIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Payment in Kira"
    static let description = IntentDescription(
        "Records a payment in Kira as pending. Use it in a Wallet Transaction automation and pass the Amount, Merchant and Card or Pass.",
        categoryName: "Payments"
    )
    static let openAppWhenRun = false
    static let isDiscoverable = true

    @Parameter(title: "Amount", description: "The transaction amount, e.g. RM12.50. Shortcuts may pass it as text or a number.")
    var amount: String?

    @Parameter(title: "Merchant")
    var merchant: String?

    @Parameter(title: "Card or Pass")
    var card: String?

    @Parameter(title: "Date", description: "Leave empty to use the current time.")
    var date: Date?

    @Parameter(title: "Reference")
    var reference: String?

    @Parameter(title: "Note")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$merchant) with \(\.$card)") {
            \.$date
            \.$reference
            \.$note
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let input = ShortcutTransactionInput(amountText: amount, merchant: merchant, cardName: card, date: date, reference: reference, notes: note)
        let item = CaptureInboxItem(receivedAt: Date(), input: input)

        // Always persist to the protected inbox first — works even while the device is locked.
        do {
            try CaptureInbox().enqueue(item)
        } catch {
            throw IntentError.couldNotSave
        }

        guard UIApplication.shared.isProtectedDataAvailable, let store = SharedEnvironment.shared.store ?? Self.makeStore() else {
            return .result(dialog: "Saved. Kira will add it when you next unlock your iPhone.")
        }
        store.tier = await SubscriptionManager.currentTier()
        guard store.gate.isAvailable(.shortcutsCapture) else {
            return .result(dialog: "Saved for later. Shortcut capture is part of Kira Plus — it will be added once Plus is active.")
        }
        store.drainInbox()
        let amountText = amount.flatMap { $0.isEmpty ? nil : $0 } ?? "an unknown amount"
        let place = merchant.flatMap { $0.isEmpty ? nil : " at \($0)" } ?? ""
        return .result(dialog: "Logged \(amountText)\(place) as pending.")
    }

    /// The intent may launch the app process in the background without UI.
    @MainActor
    private static func makeStore() -> FinanceStore? {
        guard let container = try? PersistenceController.makeContainer() else { return nil }
        let store = FinanceStore(repository: SwiftDataFinanceRepository(container: container))
        store.load()
        SharedEnvironment.shared.store = store
        return store
    }

    enum IntentError: Error, CustomLocalizedStringResourceConvertible {
        case couldNotSave
        var localizedStringResource: LocalizedStringResource { "Kira couldn’t save this payment." }
    }
}

/// Exposes the intent to Shortcuts and Siri without any setup.
struct KiraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogPaymentIntent(),
            phrases: ["Log a payment in \(.applicationName)", "Record spending in \(.applicationName)"],
            shortTitle: "Log Payment",
            systemImageName: "creditcard"
        )
    }
}
