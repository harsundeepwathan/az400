#if DEBUG
import SwiftUI
import KiraCore

/// Self-contained, synthetic data for Xcode Previews. Uses an in-memory store; nothing touches
/// disk, the network, StoreKit or the capture inbox on disk.
@MainActor
enum PreviewData {
    static let calendar = KLCalendar.shared

    static func rm(_ value: String) -> Money { Money(major: Decimal(string: value)!)! }

    static func store(empty: Bool = false) -> FinanceStore {
        let container = try! PersistenceController.makeContainer(inMemory: true)
        let inbox = CaptureInbox(directory: FileManager.default.temporaryDirectory.appendingPathComponent("KiraPreviewInbox-\(UUID().uuidString)"))
        let store = FinanceStore(repository: SwiftDataFinanceRepository(container: container), inbox: inbox)
        store.now = { calendar.date(2025, 10, 20, 9, 41) }
        store.tier = .premium
        guard !empty else { return store }

        let savings = Account(name: "Maybank Savings", type: .savings, institution: .maybank,
                              balance: rm("4180.00"), balanceVerifiedAt: calendar.date(2025, 10, 15))
        let card = Account(name: "Maybank Visa", type: .creditCard, institution: .maybank, lastFour: "4321",
                           balance: rm("812.40"), balanceVerifiedAt: calendar.date(2025, 10, 18))
        store.save(account: savings)
        store.save(account: card)
        store.save(budget: Budget(limit: rm("5000.00")))
        store.save(commitment: Commitment(name: "Rent", type: .rent, amount: rm("1500.00"), recurrence: .monthly(day: 25), startDate: calendar.date(2025, 1, 1)))
        store.save(income: IncomeSource(name: "Salary", type: .basicSalary, expectedNet: rm("6200.00"), recurrence: .monthly(day: 31), startDate: calendar.date(2025, 1, 1)))

        func tx(_ amount: String, _ merchant: String, _ category: BuiltInCategory?, day: Int, kind: TransactionKind = .expense,
                direction: TransactionDirection = .outflow, status: TransactionStatus = .confirmed, channel: PaymentChannel = .card,
                source: ImportSource = .manual, account: UUID? = nil) -> TransactionRecord {
            TransactionRecord(accountID: account ?? savings.id, amount: rm(amount), direction: direction, kind: kind, merchant: merchant,
                              transactionDescription: merchant, transactionDate: calendar.date(2025, 10, day, 12), channel: channel,
                              categoryID: category?.id, status: status, source: source)
        }
        store.upsert([
            tx("12.90", "ZUS Coffee", .coffee, day: 20, status: .pending, channel: .applePay, source: .appleShortcut, account: card.id),
            tx("23.40", "Nasi Kandar Pelita", .restaurants, day: 20, status: .draft, channel: .duitNowQR, source: .duitNowQR),
            tx("152.30", "Jaya Grocer", .groceries, day: 19),
            tx("100.00", "Touch ’n Go reload", nil, day: 19, kind: .walletTopUp),
            tx("80.00", "Petronas", .petrol, day: 18, account: card.id),
            tx("45.00", "Refund · Shopee", .shopping, day: 18, kind: .refund, direction: .inflow),
            tx("6200.00", "Salary", nil, day: 1, kind: .income, direction: .inflow),
            tx("286.50", "foodpanda", .foodDelivery, day: 12, account: card.id),
            tx("320.00", "Lotus’s", .groceries, day: 6)
        ])
        store.save(subscription: ServiceSubscription(name: "Netflix", serviceID: "netflix", amount: rm("54.90"),
                                                     nextRenewal: calendar.date(2025, 10, 21), categoryID: BuiltInCategory.entertainment.id))
        store.save(subscription: ServiceSubscription(name: "Spotify Family", serviceID: "spotify", amount: rm("29.90"),
                                                     nextRenewal: calendar.date(2025, 10, 28), shareCount: 3))
        store.save(subscription: ServiceSubscription(name: "iCloud+", serviceID: "icloud", amount: rm("12.90"),
                                                     nextRenewal: calendar.date(2025, 11, 2), billedThroughApple: true))
        store.save(subscription: ServiceSubscription(name: "Viu", serviceID: "viu", amount: rm("15.90"), nextRenewal: calendar.date(2025, 10, 24),
                                                     status: .trial, trialEndsAt: calendar.date(2025, 10, 24)))
        return store
    }
}

private struct PreviewEnvironment: ViewModifier {
    let store: FinanceStore
    func body(content: Content) -> some View {
        content
            .environment(store)
            .environment(SubscriptionManager())
            .environment(AppLock())
    }
}

extension View {
    func previewEnvironment(empty: Bool = false) -> some View {
        modifier(PreviewEnvironment(store: PreviewData.store(empty: empty)))
    }
}

#Preview("App") { RootView().previewEnvironment() }
#Preview("App · empty") { RootView().previewEnvironment(empty: true) }
#Preview("App · dark, XXXL text") {
    RootView().previewEnvironment()
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility3)
}
#Preview("Activity") { ActivityView().previewEnvironment() }
#Preview("Insights") { InsightsView().previewEnvironment() }
#Preview("Search") { SearchView().previewEnvironment() }
#Preview("Subscriptions") { NavigationStack { SubscriptionsView() }.previewEnvironment() }
#Preview("Subscriptions · empty") { NavigationStack { SubscriptionsView() }.previewEnvironment(empty: true) }
#Preview("Add transaction") { CaptureFlowView(flow: .manual).previewEnvironment() }
#endif
