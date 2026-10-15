import Foundation
import SwiftData
import KiraCore

/// Everything the app holds, as domain values.
struct FinanceSnapshot: Sendable {
    var transactions: [TransactionRecord] = []
    var accounts: [Account] = []
    var budgets: [Budget] = []
    var commitments: [Commitment] = []
    var incomes: [IncomeSource] = []
    var rules: [MerchantRule] = []
    var customCategories: [CategoryDefinition] = []
    var subscriptions: [ServiceSubscription] = []
}

/// Persistence boundary. Views and view models never touch SwiftData directly, so the store can be
/// swapped (in-memory for tests and UI tests, a sync-aware implementation later).
@MainActor
protocol FinanceRepository: AnyObject {
    func loadSnapshot() throws -> FinanceSnapshot
    func upsert(transactions: [TransactionRecord]) throws
    func deleteTransactions(ids: Set<UUID>) throws
    func upsert(account: Account) throws
    func deleteAccount(id: UUID) throws
    func upsert(budget: Budget) throws
    func deleteBudget(id: UUID) throws
    func upsert(commitment: Commitment) throws
    func deleteCommitment(id: UUID) throws
    func upsert(income: IncomeSource) throws
    func deleteIncome(id: UUID) throws
    func upsert(rule: MerchantRule) throws
    func deleteRule(id: UUID) throws
    func upsert(category: CategoryDefinition) throws
    func upsert(subscription: ServiceSubscription) throws
    func deleteSubscription(id: UUID) throws
    func recordImport(source: ImportSource, profileID: String?, fileName: String, count: Int, at date: Date) throws
    func importCount(since date: Date) throws -> Int
    func logAudit(action: String, detail: String) throws
    func auditEvents(limit: Int) throws -> [(Date, String, String)]
    /// Irreversibly removes all financial data from this device.
    func deleteAllData() throws
}

enum RepositoryError: LocalizedError {
    case corruptRecord(String)

    var errorDescription: String? {
        switch self {
        case .corruptRecord(let type): return "A saved \(type) could not be read."
        }
    }
}

@MainActor
final class SwiftDataFinanceRepository: FinanceRepository {
    let context: ModelContext
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(container: ModelContainer) {
        self.context = ModelContext(container)
        self.context.autosaveEnabled = false
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    // MARK: Load

    func loadSnapshot() throws -> FinanceSnapshot {
        var snapshot = FinanceSnapshot()
        let transactionRows = try context.fetch(FetchDescriptor<TransactionEntity>(sortBy: [SortDescriptor(\.transactionDate, order: .reverse)]))
        snapshot.transactions = try transactionRows.map { try decode(TransactionRecord.self, $0.payload) }
        snapshot.accounts = try context.fetch(FetchDescriptor<AccountEntity>()).map { try decode(Account.self, $0.payload) }
        snapshot.budgets = try context.fetch(FetchDescriptor<BudgetEntity>()).map { try decode(Budget.self, $0.payload) }
        snapshot.commitments = try context.fetch(FetchDescriptor<CommitmentEntity>()).map { try decode(Commitment.self, $0.payload) }
        snapshot.incomes = try context.fetch(FetchDescriptor<IncomeEntity>()).map { try decode(IncomeSource.self, $0.payload) }
        snapshot.rules = try context.fetch(FetchDescriptor<RuleEntity>()).map { try decode(MerchantRule.self, $0.payload) }
        snapshot.customCategories = try context.fetch(FetchDescriptor<CategoryEntity>()).map { try decode(CategoryDefinition.self, $0.payload) }
        snapshot.subscriptions = try context.fetch(FetchDescriptor<SubscriptionEntity>()).map { try decode(ServiceSubscription.self, $0.payload) }
        return snapshot
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) } catch { throw RepositoryError.corruptRecord(String(describing: type)) }
    }

    // MARK: Transactions

    func upsert(transactions: [TransactionRecord]) throws {
        guard !transactions.isEmpty else { return }
        let ids = transactions.map(\.id)
        let existing = try context.fetch(FetchDescriptor<TransactionEntity>(predicate: #Predicate { ids.contains($0.id) }))
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in transactions {
            let payload = try encoder.encode(record)
            if let entity = byID[record.id] {
                entity.transactionDate = record.transactionDate
                entity.statusRaw = record.status.rawValue
                entity.accountID = record.accountID
                entity.payload = payload
            } else {
                context.insert(TransactionEntity(id: record.id, transactionDate: record.transactionDate, statusRaw: record.status.rawValue,
                                                 accountID: record.accountID, payload: payload))
            }
        }
        try context.save()
    }

    func deleteTransactions(ids: Set<UUID>) throws {
        let list = Array(ids)
        try context.delete(model: TransactionEntity.self, where: #Predicate { list.contains($0.id) })
        try context.save()
    }

    // MARK: Simple payload entities

    func upsert(account: Account) throws {
        let id = account.id
        try upsertPayload(account, fetch: FetchDescriptor<AccountEntity>(predicate: #Predicate { $0.id == id }), make: { AccountEntity(id: id, payload: $0) }, set: { $0.payload = $1 })
    }
    func deleteAccount(id: UUID) throws {
        try context.delete(model: AccountEntity.self, where: #Predicate { $0.id == id }); try context.save()
    }

    func upsert(budget: Budget) throws {
        let id = budget.id
        try upsertPayload(budget, fetch: FetchDescriptor<BudgetEntity>(predicate: #Predicate { $0.id == id }), make: { BudgetEntity(id: id, payload: $0) }, set: { $0.payload = $1 })
    }
    func deleteBudget(id: UUID) throws {
        try context.delete(model: BudgetEntity.self, where: #Predicate { $0.id == id }); try context.save()
    }

    func upsert(commitment: Commitment) throws {
        let id = commitment.id
        try upsertPayload(commitment, fetch: FetchDescriptor<CommitmentEntity>(predicate: #Predicate { $0.id == id }), make: { CommitmentEntity(id: id, payload: $0) }, set: { $0.payload = $1 })
    }
    func deleteCommitment(id: UUID) throws {
        try context.delete(model: CommitmentEntity.self, where: #Predicate { $0.id == id }); try context.save()
    }

    func upsert(income: IncomeSource) throws {
        let id = income.id
        try upsertPayload(income, fetch: FetchDescriptor<IncomeEntity>(predicate: #Predicate { $0.id == id }), make: { IncomeEntity(id: id, payload: $0) }, set: { $0.payload = $1 })
    }
    func deleteIncome(id: UUID) throws {
        try context.delete(model: IncomeEntity.self, where: #Predicate { $0.id == id }); try context.save()
    }

    func upsert(rule: MerchantRule) throws {
        let id = rule.id
        try upsertPayload(rule, fetch: FetchDescriptor<RuleEntity>(predicate: #Predicate { $0.id == id }), make: { RuleEntity(id: id, payload: $0) }, set: { $0.payload = $1 })
    }
    func deleteRule(id: UUID) throws {
        try context.delete(model: RuleEntity.self, where: #Predicate { $0.id == id }); try context.save()
    }

    func upsert(subscription: ServiceSubscription) throws {
        let id = subscription.id
        try upsertPayload(subscription, fetch: FetchDescriptor<SubscriptionEntity>(predicate: #Predicate { $0.id == id }), make: { SubscriptionEntity(id: id, payload: $0) }, set: { $0.payload = $1 })
    }
    func deleteSubscription(id: UUID) throws {
        try context.delete(model: SubscriptionEntity.self, where: #Predicate { $0.id == id }); try context.save()
    }

    func upsert(category: CategoryDefinition) throws {
        let id = category.id
        try upsertPayload(category, fetch: FetchDescriptor<CategoryEntity>(predicate: #Predicate { $0.id == id }), make: { CategoryEntity(id: id, payload: $0) }, set: { $0.payload = $1 })
    }

    private func upsertPayload<Value: Encodable, Entity: PersistentModel>(_ value: Value, fetch: FetchDescriptor<Entity>, make: (Data) -> Entity, set: (Entity, Data) -> Void) throws {
        let payload = try encoder.encode(value)
        if let existing = try context.fetch(fetch).first {
            set(existing, payload)
        } else {
            context.insert(make(payload))
        }
        try context.save()
    }

    // MARK: Imports & audit

    func recordImport(source: ImportSource, profileID: String?, fileName: String, count: Int, at date: Date) throws {
        context.insert(ImportBatchEntity(importedAt: date, sourceRaw: source.rawValue, profileID: profileID,
                                         fileName: InputSanitizer.cleanText(fileName, maxLength: 120), transactionCount: count))
        try context.save()
    }

    func importCount(since date: Date) throws -> Int {
        try context.fetchCount(FetchDescriptor<ImportBatchEntity>(predicate: #Predicate { $0.importedAt >= date }))
    }

    func logAudit(action: String, detail: String) throws {
        context.insert(AuditEventEntity(action: action, detail: InputSanitizer.redactForLogging(detail)))
        try context.save()
    }

    func auditEvents(limit: Int) throws -> [(Date, String, String)] {
        var descriptor = FetchDescriptor<AuditEventEntity>(sortBy: [SortDescriptor(\.occurredAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).map { ($0.occurredAt, $0.action, $0.detail) }
    }

    func deleteAllData() throws {
        try context.delete(model: TransactionEntity.self)
        try context.delete(model: AccountEntity.self)
        try context.delete(model: BudgetEntity.self)
        try context.delete(model: CommitmentEntity.self)
        try context.delete(model: IncomeEntity.self)
        try context.delete(model: RuleEntity.self)
        try context.delete(model: CategoryEntity.self)
        try context.delete(model: ImportBatchEntity.self)
        try context.delete(model: SubscriptionEntity.self)
        try context.delete(model: AuditEventEntity.self)
        try context.save()
    }
}
