import Foundation
import SwiftData

// Persistence model.
//
// Domain types live in KiraCore as plain Codable structs. Each entity stores the encoded struct
// (`payload`) plus the few columns needed for queries/sorting. This keeps the domain layer
// platform-independent and testable on Linux, and makes schema evolution a Codable concern
// (new optional fields decode as nil) rather than a SwiftData migration for every change.
//
// The store file is protected with iOS Data Protection (NSFileProtectionComplete): it is
// encrypted with a key derived from the device passcode and unreadable while the device is locked.

@Model
final class TransactionEntity {
    @Attribute(.unique) var id: UUID
    var transactionDate: Date
    var statusRaw: String
    var accountID: UUID?
    var payload: Data

    init(id: UUID, transactionDate: Date, statusRaw: String, accountID: UUID?, payload: Data) {
        self.id = id
        self.transactionDate = transactionDate
        self.statusRaw = statusRaw
        self.accountID = accountID
        self.payload = payload
    }
}

@Model
final class AccountEntity {
    @Attribute(.unique) var id: UUID
    var payload: Data
    init(id: UUID, payload: Data) { self.id = id; self.payload = payload }
}

@Model
final class BudgetEntity {
    @Attribute(.unique) var id: UUID
    var payload: Data
    init(id: UUID, payload: Data) { self.id = id; self.payload = payload }
}

@Model
final class CommitmentEntity {
    @Attribute(.unique) var id: UUID
    var payload: Data
    init(id: UUID, payload: Data) { self.id = id; self.payload = payload }
}

@Model
final class IncomeEntity {
    @Attribute(.unique) var id: UUID
    var payload: Data
    init(id: UUID, payload: Data) { self.id = id; self.payload = payload }
}

@Model
final class RuleEntity {
    @Attribute(.unique) var id: UUID
    var payload: Data
    init(id: UUID, payload: Data) { self.id = id; self.payload = payload }
}

@Model
final class CategoryEntity {
    @Attribute(.unique) var id: String
    var payload: Data
    init(id: String, payload: Data) { self.id = id; self.payload = payload }
}

/// A tracked service subscription (Netflix, Spotify…).
@Model
final class SubscriptionEntity {
    @Attribute(.unique) var id: UUID
    var payload: Data
    init(id: UUID, payload: Data) { self.id = id; self.payload = payload }
}

/// One statement/receipt import, for the free-tier monthly limit and the import history screen.
@Model
final class ImportBatchEntity {
    @Attribute(.unique) var id: UUID
    var importedAt: Date
    var sourceRaw: String
    var profileID: String?
    var fileName: String
    var transactionCount: Int

    init(id: UUID = UUID(), importedAt: Date, sourceRaw: String, profileID: String?, fileName: String, transactionCount: Int) {
        self.id = id
        self.importedAt = importedAt
        self.sourceRaw = sourceRaw
        self.profileID = profileID
        self.fileName = fileName
        self.transactionCount = transactionCount
    }
}

/// Local audit trail of sensitive operations (exports, deletions, lock changes). Contains no amounts.
@Model
final class AuditEventEntity {
    var occurredAt: Date
    var action: String
    var detail: String

    init(occurredAt: Date = Date(), action: String, detail: String) {
        self.occurredAt = occurredAt
        self.action = action
        self.detail = detail
    }
}

enum KiraSchema {
    static let models: [any PersistentModel.Type] = [
        TransactionEntity.self, AccountEntity.self, BudgetEntity.self, CommitmentEntity.self, IncomeEntity.self,
        RuleEntity.self, CategoryEntity.self, SubscriptionEntity.self, ImportBatchEntity.self, AuditEventEntity.self
    ]
}
