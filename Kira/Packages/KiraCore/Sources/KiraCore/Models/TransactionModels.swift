import Foundation

/// Which way money moved relative to the account the transaction belongs to.
public enum TransactionDirection: String, Codable, CaseIterable, Sendable {
    case outflow
    case inflow
}

/// Economic meaning of a transaction. This — not the sign — decides whether something
/// counts as spending. Getting this right is what prevents double-counting.
public enum TransactionKind: String, Codable, CaseIterable, Sendable {
    /// Consumption: buying goods or services.
    case expense
    /// Salary, freelance, rental, bonus and other earnings.
    case income
    /// Movement between two accounts the user owns. Never spending or income.
    case transfer
    /// Paying off a credit card from another account. The purchases were already counted.
    case creditCardRepayment
    /// Loading an e-wallet (TNG, GrabPay, Boost, ShopeePay). Spending happens when the wallet is used.
    case walletTopUp
    /// Merchant refund of an earlier expense. Reduces net spending.
    case refund
    /// Bank/network reversal of an earlier debit. Reduces net spending.
    case reversal
    /// Bank charges, interest, late fees, finance charges. Counts as spending (Debt Interest & Fees).
    case fee
    /// Instalment toward loan principal (mortgage, car, PTPTN, personal loan, BNPL).
    /// Reported as debt cash outflow, not consumption.
    case debtRepayment

    public var displayName: String {
        switch self {
        case .expense: return "Expense"
        case .income: return "Income"
        case .transfer: return "Transfer"
        case .creditCardRepayment: return "Card repayment"
        case .walletTopUp: return "E-wallet top-up"
        case .refund: return "Refund"
        case .reversal: return "Reversal"
        case .fee: return "Fee"
        case .debtRepayment: return "Loan repayment"
        }
    }

    /// Kinds that are internal money movement rather than consumption or earnings.
    public var isInternalMovement: Bool {
        switch self {
        case .transfer, .creditCardRepayment, .walletTopUp: return true
        default: return false
        }
    }

    /// Natural direction for this kind (used to validate imports and manual entry).
    public var expectedDirection: TransactionDirection? {
        switch self {
        case .expense, .fee, .debtRepayment, .walletTopUp, .creditCardRepayment: return .outflow
        case .income, .refund, .reversal: return .inflow
        case .transfer: return nil
        }
    }
}

/// Lifecycle of a captured transaction.
public enum TransactionStatus: String, Codable, CaseIterable, Sendable {
    /// Intent only (e.g. scanned DuitNow QR). Payment NOT confirmed. Excluded from totals.
    case draft
    /// Evidence of a payment exists (e.g. Wallet tap automation) but it has not been confirmed
    /// by a receipt, statement or the user.
    case pending
    /// Confirmed by the user, a receipt, or a statement import.
    case confirmed
    /// Confirmed and matched against an authoritative statement record.
    case reconciled
    /// Merged into another record during reconciliation. Kept for audit, excluded from totals.
    case superseded

    public var displayName: String {
        switch self {
        case .draft: return "Draft"
        case .pending: return "Pending"
        case .confirmed: return "Confirmed"
        case .reconciled: return "Reconciled"
        case .superseded: return "Merged"
        }
    }
}

/// How the payment was made.
public enum PaymentChannel: String, Codable, CaseIterable, Sendable {
    case applePay
    case card
    case duitNowQR
    case duitNowTransfer
    case fpx
    case jomPay
    case eWallet
    case bankTransfer
    case cash
    case directDebit
    case atm
    case other

    public var displayName: String {
        switch self {
        case .applePay: return "Apple Pay"
        case .card: return "Card"
        case .duitNowQR: return "DuitNow QR"
        case .duitNowTransfer: return "DuitNow Transfer"
        case .fpx: return "FPX"
        case .jomPay: return "JomPAY"
        case .eWallet: return "E-wallet"
        case .bankTransfer: return "Bank transfer"
        case .cash: return "Cash"
        case .directDebit: return "Direct debit"
        case .atm: return "ATM"
        case .other: return "Other"
        }
    }
}

/// Where a record came from. Ordered by evidential authority for reconciliation.
public enum ImportSource: String, Codable, CaseIterable, Sendable {
    case manual
    case appleShortcut
    case duitNowQR
    case receiptImage
    case receiptDocument
    case eWalletStatement
    case bankStatementCSV
    case bankStatementPDF
    case financeKit

    /// Higher wins when two records describe the same payment.
    public var authority: Int {
        switch self {
        case .duitNowQR: return 0
        case .appleShortcut: return 1
        case .manual: return 2
        case .receiptImage, .receiptDocument: return 3
        case .eWalletStatement: return 4
        case .bankStatementPDF: return 5
        case .bankStatementCSV: return 6
        case .financeKit: return 7
        }
    }

    public var isStatement: Bool {
        switch self {
        case .eWalletStatement, .bankStatementCSV, .bankStatementPDF, .financeKit: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .manual: return "Manual entry"
        case .appleShortcut: return "Apple Pay Shortcut"
        case .duitNowQR: return "DuitNow QR scan"
        case .receiptImage: return "Receipt image"
        case .receiptDocument: return "Receipt document"
        case .eWalletStatement: return "E-wallet statement"
        case .bankStatementCSV: return "Bank statement (CSV)"
        case .bankStatementPDF: return "Bank statement (PDF)"
        case .financeKit: return "FinanceKit"
        }
    }
}

/// Reasons a record needs the user's attention.
public enum ReviewFlag: String, Codable, CaseIterable, Sendable {
    /// Amount unknown (e.g. Wallet automation delivered 0 / blank). Excluded from totals.
    case amountMissing
    case merchantMissing
    case lowConfidenceCategory
    case possibleDuplicate
    case unconfirmedPayment
    case directionUncertain
    case foreignCurrency
}

/// The normalised transaction model shared by every capture path.
public struct TransactionRecord: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var accountID: UUID?
    /// Non-negative magnitude. Direction carries the sign.
    public var amount: Money
    public var direction: TransactionDirection
    public var kind: TransactionKind
    public var merchant: String?
    public var transactionDescription: String
    /// When the payment happened (local Malaysia time).
    public var transactionDate: Date
    /// When the bank posted it, if known.
    public var postingDate: Date?
    public var channel: PaymentChannel
    public var categoryID: String?
    /// True when the user explicitly chose the category — automated rules never overwrite it.
    public var categoryIsUserSet: Bool
    public var status: TransactionStatus
    public var source: ImportSource
    public var externalReference: String?
    /// 0...1 confidence in extracted fields / categorisation.
    public var confidence: Double
    public var flags: Set<ReviewFlag>
    public var notes: String?
    /// Merchant category code (from QR or card data) when available.
    public var merchantCategoryCode: String?
    /// Links a refund/reversal to the original, or a transfer leg to its counterpart.
    public var linkedTransactionID: UUID?
    /// Set when this record was merged into another during reconciliation.
    public var supersededBy: UUID?
    /// Stable hash used for import idempotency.
    public var importFingerprint: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        accountID: UUID? = nil,
        amount: Money,
        direction: TransactionDirection,
        kind: TransactionKind,
        merchant: String? = nil,
        transactionDescription: String = "",
        transactionDate: Date,
        postingDate: Date? = nil,
        channel: PaymentChannel = .other,
        categoryID: String? = nil,
        categoryIsUserSet: Bool = false,
        status: TransactionStatus = .confirmed,
        source: ImportSource = .manual,
        externalReference: String? = nil,
        confidence: Double = 1.0,
        flags: Set<ReviewFlag> = [],
        notes: String? = nil,
        merchantCategoryCode: String? = nil,
        linkedTransactionID: UUID? = nil,
        supersededBy: UUID? = nil,
        importFingerprint: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        precondition(!amount.isNegative, "TransactionRecord.amount is a magnitude; use direction for sign")
        self.id = id
        self.accountID = accountID
        self.amount = amount
        self.direction = direction
        self.kind = kind
        self.merchant = merchant
        self.transactionDescription = transactionDescription
        self.transactionDate = transactionDate
        self.postingDate = postingDate
        self.channel = channel
        self.categoryID = categoryID
        self.categoryIsUserSet = categoryIsUserSet
        self.status = status
        self.source = source
        self.externalReference = externalReference
        self.confidence = min(max(confidence, 0), 1)
        self.flags = flags
        self.notes = notes
        self.merchantCategoryCode = merchantCategoryCode
        self.linkedTransactionID = linkedTransactionID
        self.supersededBy = supersededBy
        self.importFingerprint = importFingerprint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Signed amount from the account's point of view (outflow negative).
    public var signedAmount: Money {
        direction == .outflow ? amount.negated : amount
    }

    /// Best label for lists.
    public var displayName: String {
        if let merchant, !merchant.isEmpty { return merchant }
        if !transactionDescription.isEmpty { return transactionDescription }
        return kind.displayName
    }
}
