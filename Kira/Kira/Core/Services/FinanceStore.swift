import Foundation
import Observation
import KiraCore
import os

/// A pending import awaiting the user's reconciliation decisions.
struct ImportReview: Identifiable {
    enum Decision: Equatable {
        case keep
        case merge(UUID)
        case skip
    }

    struct Item: Identifiable {
        var id: UUID { incoming.id }
        var incoming: TransactionRecord
        let disposition: ReconciliationEngine.Disposition
        var decision: Decision

        var needsAttention: Bool {
            switch disposition {
            case .likelyMatch, .ambiguous: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let source: ImportSource
    let profileID: String?
    let fileName: String
    var items: [Item]
    var warnings: [String]
    var skippedRows: [ImportResult.SkippedRow]

    var newCount: Int { items.filter { $0.decision == .keep }.count }
    var mergeCount: Int { items.filter { if case .merge = $0.decision { return true } else { return false } }.count }
    var skipCount: Int { items.filter { $0.decision == .skip }.count }
}

struct FeedbackEvent: Equatable {
    enum Kind { case success, warning }
    let kind: Kind
    /// Unique per event so two successive saves both trigger feedback.
    let id = UUID()
}

/// App-wide state and use cases. Holds the domain snapshot in memory, delegates every
/// calculation to KiraCore engines and every write to the repository.
@MainActor
@Observable
final class FinanceStore {
    private(set) var transactions: [TransactionRecord] = []
    private(set) var accounts: [Account] = []
    private(set) var budgets: [Budget] = []
    private(set) var commitments: [Commitment] = []
    private(set) var incomes: [IncomeSource] = []
    private(set) var rules: [MerchantRule] = []
    private(set) var customCategories: [CategoryDefinition] = []
    private(set) var subscriptions: [ServiceSubscription] = []
    private(set) var loadError: String?
    var lastErrorMessage: String?

    /// Latest haptic-worthy outcome. `RootView` plays it with `sensoryFeedback`, so feedback fires on
    /// the same frame as the UI change and only for meaningful moments (save, error).
    private(set) var feedback: FeedbackEvent?

    var tier: SubscriptionTier = .free
    var gate: FeatureGate { FeatureGate(tier: tier) }

    let repository: FinanceRepository
    let inbox: CaptureInbox
    private let logger = Logger(subsystem: "my.kira.app", category: "store")
    private let calendar = KLCalendar.shared
    let ledger = LedgerCalculator()
    let categoryEngine = CategoryEngine()
    let reconciliation = ReconciliationEngine()
    let subscriptionEngine = SubscriptionEngine()
    var now: () -> Date = { Date() }

    init(repository: FinanceRepository, inbox: CaptureInbox = CaptureInbox()) {
        self.repository = repository
        self.inbox = inbox
    }

    // MARK: Loading

    func load() {
        do {
            let snapshot = try repository.loadSnapshot()
            transactions = snapshot.transactions.sorted { $0.transactionDate > $1.transactionDate }
            accounts = snapshot.accounts
            budgets = snapshot.budgets
            commitments = snapshot.commitments
            incomes = snapshot.incomes
            rules = snapshot.rules
            customCategories = snapshot.customCategories
            // Stale renewal dates roll forward on load so "next renewal" is never in the past.
            subscriptions = snapshot.subscriptions.map { subscriptionEngine.rolledForward($0, now: now()) }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            logger.error("Load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Categories

    var categories: [CategoryDefinition] {
        BuiltInCategory.allDefinitions + customCategories.filter { !$0.isArchived }
    }

    func category(_ id: String?) -> CategoryDefinition? {
        guard let id else { return nil }
        return categories.first { $0.id == id } ?? customCategories.first { $0.id == id }
    }

    func addCustomCategory(name: String, symbol: String, tint: String, discretionary: Bool) {
        let cleaned = InputSanitizer.cleanText(name, maxLength: 40)
        guard !cleaned.isEmpty else { return }
        let definition = CategoryDefinition(id: UUID().uuidString, name: cleaned, symbol: symbol, tint: tint, isBuiltIn: false, isDiscretionary: discretionary)
        perform { try repository.upsert(category: definition) } then: { customCategories.append(definition) }
    }

    // MARK: Accounts

    var activeAccounts: [Account] { accounts.filter { !$0.isArchived } }

    func account(_ id: UUID?) -> Account? { id.flatMap { id in accounts.first { $0.id == id } } }

    func save(account: Account) {
        var account = account
        account.name = InputSanitizer.cleanText(account.name, maxLength: 60)
        perform { try repository.upsert(account: account) } then: {
            if let index = accounts.firstIndex(where: { $0.id == account.id }) { accounts[index] = account } else { accounts.append(account) }
        }
    }

    /// Archiving keeps history intact; transactions keep their account link.
    func archive(account: Account) {
        var archived = account
        archived.isArchived = true
        save(account: archived)
    }

    // MARK: Transactions

    func transaction(_ id: UUID) -> TransactionRecord? { transactions.first { $0.id == id } }

    /// Visible records (merged duplicates are hidden but retained).
    var visibleTransactions: [TransactionRecord] { transactions.filter { $0.status != .superseded } }

    var needsReview: [TransactionRecord] {
        visibleTransactions.filter { record in
            record.status == .draft || record.status == .pending ||
                !record.flags.isDisjoint(with: [.amountMissing, .directionUncertain, .lowConfidenceCategory, .possibleDuplicate, .foreignCurrency])
        }
    }

    /// Saves a manually entered record. A category the user picked is kept; otherwise the engine suggests one.
    func addManual(_ record: TransactionRecord) {
        var record = categoryEngine.apply(to: record, rules: rules)
        record.source = .manual
        upsert([record])
        signal(.success)
    }

    /// Saves an edited record. If the category changed, the choice is marked as the user's and a
    /// rule is learned for *future* transactions from the same merchant.
    func update(_ record: TransactionRecord, previous: TransactionRecord?) {
        var record = record
        record.updatedAt = now()
        record.flags.remove(.lowConfidenceCategory)
        if let previous, previous.categoryID != record.categoryID, let newCategory = record.categoryID {
            record.categoryIsUserSet = true
            learnRule(from: record, categoryID: newCategory)
        }
        if record.amount.minorUnits > 0 { record.flags.remove(.amountMissing) }
        if record.merchant?.isEmpty == false { record.flags.remove(.merchantMissing) }
        upsert([record])
    }

    func confirm(_ record: TransactionRecord) {
        var record = record
        guard !record.flags.contains(.amountMissing) else {
            lastErrorMessage = "Add the amount before confirming this payment."
            return
        }
        record.status = .confirmed
        record.flags.remove(.unconfirmedPayment)
        record.updatedAt = now()
        upsert([record])
        signal(.success)
    }

    func delete(_ ids: Set<UUID>) {
        perform { try repository.deleteTransactions(ids: ids) } then: {
            transactions.removeAll { ids.contains($0.id) }
        }
    }

    private func learnRule(from record: TransactionRecord, categoryID: String) {
        guard let rule = CategoryEngine.learnRule(from: record, newCategoryID: categoryID, now: now()) else { return }
        // Replace an earlier learned rule for the same merchant.
        let stale = rules.filter { $0.learnedFromCorrection && $0.pattern == rule.pattern }
        for old in stale { try? repository.deleteRule(id: old.id) }
        rules.removeAll { old in stale.contains { $0.id == old.id } }
        perform { try repository.upsert(rule: rule) } then: { rules.append(rule) }
    }

    func save(rule: MerchantRule) {
        perform { try repository.upsert(rule: rule) } then: {
            if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
        }
    }

    func deleteRule(_ rule: MerchantRule) {
        perform { try repository.deleteRule(id: rule.id) } then: { rules.removeAll { $0.id == rule.id } }
    }

    func upsert(_ records: [TransactionRecord]) {
        perform { try repository.upsert(transactions: records) } then: {
            for record in records {
                if let index = transactions.firstIndex(where: { $0.id == record.id }) { transactions[index] = record } else { transactions.append(record) }
            }
            transactions.sort { $0.transactionDate > $1.transactionDate }
        }
    }

    // MARK: Shortcut capture

    enum CaptureResult: Equatable { case saved, duplicate, rejected(String), requiresPlus }

    func ingest(_ input: ShortcutTransactionInput, receivedAt: Date) -> CaptureResult {
        guard gate.isAvailable(.shortcutsCapture) else { return .requiresPlus }
        let processor = ShortcutCaptureProcessor(engine: categoryEngine)
        switch processor.process(input, receivedAt: receivedAt, accounts: accounts, existing: transactions, rules: rules) {
        case .created(let record):
            upsert([record])
            return .saved
        case .duplicate:
            return .duplicate
        case .rejected(let reason):
            return .rejected(reason)
        }
    }

    /// Moves captures written while locked into the store.
    func drainInbox() {
        for (url, item) in inbox.pending() {
            switch ingest(item.input, receivedAt: item.receivedAt) {
            case .saved, .duplicate, .rejected:
                inbox.remove(url)
            case .requiresPlus:
                // Keep it: if the user subscribes, it is not lost. Visible in Settings › Shortcuts.
                break
            }
        }
    }

    var inboxPendingCount: Int { inbox.pending().count }

    // MARK: Imports & reconciliation

    func importsThisMonth() -> Int {
        (try? repository.importCount(since: calendar.monthInterval(containing: now()).start)) ?? 0
    }

    var canImport: Bool { gate.canImport(importsThisMonth: importsThisMonth()) }

    /// Builds a review: exact duplicates are skipped, reference matches merged, likely matches
    /// pre-selected, ambiguous ones left for the user, everything else kept as new.
    func prepareReview(_ incoming: [TransactionRecord], source: ImportSource, profileID: String?, fileName: String,
                       warnings: [String] = [], skipped: [ImportResult.SkippedRow] = []) -> ImportReview {
        let categorised = incoming.map { categoryEngine.apply(to: $0, rules: rules) }
        let plan = reconciliation.plan(incoming: categorised, existing: transactions)
        let items = plan.map { item -> ImportReview.Item in
            let decision: ImportReview.Decision
            switch item.disposition {
            case .exactDuplicate: decision = .skip
            case .autoMerge(let id): decision = .merge(id)
            case .likelyMatch(let candidate): decision = .merge(candidate.existingID)
            case .ambiguous, .new: decision = .keep
            }
            return ImportReview.Item(incoming: item.incoming, disposition: item.disposition, decision: decision)
        }
        return ImportReview(source: source, profileID: profileID, fileName: fileName, items: items, warnings: warnings, skippedRows: skipped)
    }

    func commit(_ review: ImportReview) {
        var toSave: [TransactionRecord] = []
        for item in review.items {
            switch item.decision {
            case .skip:
                continue
            case .keep:
                var record = item.incoming
                if case .ambiguous = item.disposition { record.flags.insert(.possibleDuplicate) }
                toSave.append(record)
            case .merge(let existingID):
                guard let existing = transaction(existingID) ?? toSave.first(where: { $0.id == existingID }) else {
                    toSave.append(item.incoming); continue
                }
                let merged = reconciliation.merge(existing: existing, incoming: item.incoming, now: now())
                toSave.removeAll { $0.id == merged.id }
                toSave.append(merged)
            }
        }
        upsert(toSave)
        if review.source.isStatement || review.source == .receiptImage || review.source == .receiptDocument {
            try? repository.recordImport(source: review.source, profileID: review.profileID, fileName: review.fileName,
                                         count: toSave.count, at: now())
        }
        signal(.success)
    }

    /// Manual merge of two stored records from the review list.
    func merge(keep: TransactionRecord, duplicate: TransactionRecord) {
        let (kept, superseded) = reconciliation.mergeStored(keep: keep, duplicate: duplicate, now: now())
        upsert([kept, superseded])
    }

    func duplicateCandidates(for record: TransactionRecord) -> [(TransactionRecord, ReconciliationEngine.Candidate)] {
        reconciliation.candidates(for: record, in: visibleTransactions.filter { $0.id != record.id })
            .compactMap { candidate in transaction(candidate.existingID).map { ($0, candidate) } }
    }

    // MARK: Subscriptions

    var liveSubscriptions: [ServiceSubscription] { subscriptions.filter(\.isLive) }

    func subscription(_ id: UUID) -> ServiceSubscription? { subscriptions.first { $0.id == id } }

    var subscriptionSummary: SubscriptionSummary { subscriptionEngine.summary(subscriptions, now: now()) }

    var subscriptionAlerts: [SubscriptionAlert] {
        subscriptionEngine.alerts(subscriptions, transactions: transactions, now: now())
    }

    /// Recurring charges found in recorded transactions that aren't tracked yet.
    var subscriptionSuggestions: [SubscriptionSuggestion] {
        subscriptionEngine.suggestions(transactions: transactions, existing: subscriptions)
    }

    func save(subscription: ServiceSubscription) {
        var subscription = subscriptionEngine.rolledForward(subscription, now: now())
        subscription.name = InputSanitizer.cleanText(subscription.name, maxLength: 60)
        subscription.matchPattern = InputSanitizer.cleanOptional(subscription.matchPattern, maxLength: 60)
        subscription.notes = InputSanitizer.cleanOptional(subscription.notes, maxLength: 500)
        subscription.updatedAt = now()
        guard !subscription.name.isEmpty else { lastErrorMessage = "Give this subscription a name."; return }
        perform { try repository.upsert(subscription: subscription) } then: {
            if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) { subscriptions[index] = subscription } else { subscriptions.append(subscription) }
            signal(.success)
        }
        Task { await SubscriptionReminders.reschedule(subscriptions, engine: subscriptionEngine, now: now()) }
    }

    /// Records the user's own cancellation. Kira can't cancel with the provider.
    func markCancelled(_ subscription: ServiceSubscription) {
        var cancelled = subscription
        cancelled.status = .cancelled
        cancelled.cancelledAt = now()
        save(subscription: cancelled)
    }

    func deleteSubscription(_ subscription: ServiceSubscription) {
        perform { try repository.deleteSubscription(id: subscription.id) } then: {
            subscriptions.removeAll { $0.id == subscription.id }
        }
        Task { await SubscriptionReminders.reschedule(subscriptions, engine: subscriptionEngine, now: now()) }
    }

    /// Commitments plus live subscriptions, so forecasts and insights include renewals once.
    /// Commitments the user entered as "Subscription" type are kept; the engine's duplicate-charge
    /// check stops the same renewal being counted twice in a month.
    var plannedCommitments: [Commitment] {
        let fromSubscriptions = subscriptions.compactMap(subscriptionEngine.commitment(for:))
        let trackedNames = Set(fromSubscriptions.map { MerchantNormalizer.key($0.name) })
        return commitments.filter { !($0.type == .subscription && trackedNames.contains(MerchantNormalizer.key($0.name))) } + fromSubscriptions
    }

    // MARK: Budgets, commitments, income

    var monthlyBudget: Budget? { budgets.first { $0.categoryID == nil && $0.period == .monthly && $0.isActive } }
    var categoryBudgets: [Budget] { budgets.filter { $0.categoryID != nil && $0.isActive } }

    func save(budget: Budget) {
        perform { try repository.upsert(budget: budget) } then: {
            if let index = budgets.firstIndex(where: { $0.id == budget.id }) { budgets[index] = budget } else { budgets.append(budget) }
        }
    }

    func deleteBudget(_ budget: Budget) {
        perform { try repository.deleteBudget(id: budget.id) } then: { budgets.removeAll { $0.id == budget.id } }
    }

    func save(commitment: Commitment) {
        var commitment = commitment
        commitment.name = InputSanitizer.cleanText(commitment.name, maxLength: 60)
        perform { try repository.upsert(commitment: commitment) } then: {
            if let index = commitments.firstIndex(where: { $0.id == commitment.id }) { commitments[index] = commitment } else { commitments.append(commitment) }
        }
    }

    func deleteCommitment(_ commitment: Commitment) {
        perform { try repository.deleteCommitment(id: commitment.id) } then: { commitments.removeAll { $0.id == commitment.id } }
    }

    func save(income: IncomeSource) {
        var income = income
        income.name = InputSanitizer.cleanText(income.name, maxLength: 60)
        perform { try repository.upsert(income: income) } then: {
            if let index = incomes.firstIndex(where: { $0.id == income.id }) { incomes[index] = income } else { incomes.append(income) }
        }
    }

    func deleteIncome(_ income: IncomeSource) {
        perform { try repository.deleteIncome(id: income.id) } then: { incomes.removeAll { $0.id == income.id } }
    }

    // MARK: Derived figures (all via KiraCore engines)

    var currentMonth: DateInterval { calendar.monthInterval(containing: now()) }

    func summary(for interval: DateInterval) -> LedgerSummary {
        ledger.summarize(transactions, filter: TransactionFilter(dateInterval: interval))
    }

    /// Previous month up to the same day, for a fair comparison.
    var comparablePreviousMonth: DateInterval {
        let previous = calendar.previousMonthInterval(before: now())
        let elapsed = calendar.dayDistance(from: currentMonth.start, to: now()) + 1
        return DateInterval(start: previous.start, end: min(calendar.addingDays(elapsed, to: previous.start), previous.end))
    }

    func budgetStatus(_ budget: Budget) -> BudgetStatus {
        BudgetEngine(ledger: ledger).status(for: budget, on: now(), transactions: transactions)
    }

    func forecast() -> CashFlowForecast {
        CashFlowForecaster(ledger: ledger).forecast(asOf: now(), accounts: accounts, transactions: transactions,
                                                    commitments: plannedCommitments, incomes: incomes, monthlyBudget: monthlyBudget, categories: categories)
    }

    func insights() -> [Insight] {
        InsightGenerator(analytics: AnalyticsEngine(ledger: ledger), categories: categories)
            .insights(now: now(), transactions: transactions, commitments: plannedCommitments, monthlyBudget: monthlyBudget)
    }

    var outstandingCardBalances: Money {
        activeAccounts.filter { $0.type == .creditCard }.compactMap(\.balance).sum()
    }

    // MARK: Privacy

    func exportCSV() -> String {
        try? repository.logAudit(action: "export.csv", detail: "\(transactions.count) transactions")
        return DataExporter.csv(transactions: transactions, accounts: accounts, categories: categories)
    }

    func exportJSON() throws -> Data {
        try? repository.logAudit(action: "export.json", detail: "full snapshot")
        return try DataExporter.json(DataExporter.Snapshot(exportedAt: now(), accounts: accounts, transactions: transactions, budgets: budgets,
                                                           commitments: commitments, incomes: incomes, rules: rules, customCategories: customCategories,
                                                           subscriptions: subscriptions))
    }

    /// Deletes every record, the capture inbox, Keychain secrets and preferences.
    func deleteAllData() throws {
        try repository.deleteAllData()
        inbox.removeAll()
        try KeychainStore().removeAll()
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        transactions = []; accounts = []; budgets = []; commitments = []; incomes = []; rules = []; customCategories = []; subscriptions = []
        SubscriptionReminders.removeAll()
    }

    // MARK: Helpers

    func signal(_ kind: FeedbackEvent.Kind) {
        feedback = FeedbackEvent(kind: kind)
    }

    private func perform(_ work: () throws -> Void, then apply: () -> Void) {
        do {
            try work()
            apply()
        } catch {
            lastErrorMessage = "Couldn’t save. \(error.localizedDescription)"
            logger.error("Save failed: \(error.localizedDescription, privacy: .public)")
            signal(.warning)
        }
    }
}
