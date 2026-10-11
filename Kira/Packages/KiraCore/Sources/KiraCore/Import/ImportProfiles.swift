import Foundation

/// Logical columns found in statement exports.
public enum StatementColumn: String, CaseIterable, Sendable {
    case date, postingDate, description, description2, debit, credit, amount, balance, reference, status, type
}

/// How a statement expresses direction.
public enum AmountConvention: String, Sendable {
    /// Separate debit/withdrawal and credit/deposit columns.
    case debitCreditColumns
    /// One signed column; negative = money out (bank style).
    case signedNegativeIsOutflow
    /// One signed column; positive = money out (credit-card statement style).
    case signedPositiveIsOutflow
    /// Decide per file from the detected columns.
    case auto
}

/// Per-institution import configuration. Profiles are header-driven, so they tolerate column
/// re-ordering. `layoutVerified` stays false until the layout has been checked against a real
/// (redacted) export from that institution — see docs/FEASIBILITY.md.
public struct ImportProfile: Identifiable, Sendable {
    public let id: String
    public let institution: Institution
    public let displayName: String
    public let accountType: AccountType
    public let headerSynonyms: [StatementColumn: [String]]
    public let convention: AmountConvention
    /// Description fragments that mark non-transaction rows (balances, totals).
    public let summaryRowMarkers: [String]
    /// Status values meaning "did not happen".
    public let failedStatusMarkers: [String]
    public let layoutVerified: Bool

    public init(id: String, institution: Institution, displayName: String, accountType: AccountType,
                extraSynonyms: [StatementColumn: [String]] = [:], convention: AmountConvention = .auto,
                extraSummaryMarkers: [String] = [], layoutVerified: Bool = false) {
        self.id = id
        self.institution = institution
        self.displayName = displayName
        self.accountType = accountType
        var synonyms = ImportProfile.baseSynonyms
        for (column, values) in extraSynonyms { synonyms[column, default: []].insert(contentsOf: values, at: 0) }
        self.headerSynonyms = synonyms
        self.convention = convention
        self.summaryRowMarkers = ImportProfile.baseSummaryMarkers + extraSummaryMarkers
        self.failedStatusMarkers = ["FAIL", "UNSUCCESSFUL", "CANCEL", "REJECT", "DECLINED", "GAGAL", "PENDING REFUND"]
        self.layoutVerified = layoutVerified
    }

    static let baseSynonyms: [StatementColumn: [String]] = [
        .date: ["transaction date", "trans date", "txn date", "date", "tarikh transaksi", "tarikh", "date & time", "date/time", "datetime"],
        .postingDate: ["posting date", "post date", "posted date", "value date", "tarikh pos", "effective date"],
        .description: ["description", "transaction description", "details", "transaction details", "keterangan", "butiran", "particulars", "merchant", "narrative", "remarks"],
        .description2: ["description 2", "additional details", "recipient", "beneficiary", "reference 2", "other details"],
        .debit: ["debit", "debit amount", "withdrawal", "withdrawals", "money out", "pengeluaran", "debit (rm)", "debit(rm)", "dr"],
        .credit: ["credit", "credit amount", "deposit", "deposits", "money in", "simpanan", "credit (rm)", "credit(rm)", "cr"],
        .amount: ["amount", "amount (rm)", "amount(rm)", "transaction amount", "jumlah", "amaun", "amount myr"],
        .balance: ["balance", "running balance", "baki", "ledger balance", "wallet balance", "balance (rm)", "available balance"],
        .reference: ["reference", "reference no", "reference number", "ref", "ref no", "transaction id", "no. rujukan", "rujukan", "transaction no"],
        .status: ["status", "transaction status"],
        .type: ["transaction type", "type", "jenis transaksi"]
    ]

    static let baseSummaryMarkers = ["OPENING BALANCE", "CLOSING BALANCE", "BEGINNING BALANCE", "ENDING BALANCE", "BALANCE B/F", "BALANCE C/F",
                                     "BAL B/F", "BAL C/F", "BROUGHT FORWARD", "CARRIED FORWARD", "BAKI MULA", "BAKI AKHIR", "BAKI DIBAWA",
                                     "TOTAL DEBIT", "TOTAL CREDIT", "TOTAL AMOUNT", "TOTAL FOR", "JUMLAH KESELURUHAN", "PREVIOUS BALANCE", "STATEMENT BALANCE",
                                     "MINIMUM PAYMENT", "PAYMENT DUE"]

    public static let all: [ImportProfile] = [
        ImportProfile(id: "maybank", institution: .maybank, displayName: "Maybank / MAE", accountType: .savings),
        ImportProfile(id: "maybank-card", institution: .maybank, displayName: "Maybank credit card", accountType: .creditCard, convention: .signedPositiveIsOutflow),
        ImportProfile(id: "cimb", institution: .cimb, displayName: "CIMB", accountType: .savings),
        ImportProfile(id: "publicbank", institution: .publicBank, displayName: "Public Bank", accountType: .savings),
        ImportProfile(id: "rhb", institution: .rhb, displayName: "RHB", accountType: .savings),
        ImportProfile(id: "hongleong", institution: .hongLeong, displayName: "Hong Leong Bank", accountType: .savings),
        ImportProfile(id: "ambank", institution: .ambank, displayName: "AmBank", accountType: .savings),
        ImportProfile(id: "bankislam", institution: .bankIslam, displayName: "Bank Islam", accountType: .savings),
        ImportProfile(id: "muamalat", institution: .bankMuamalat, displayName: "Bank Muamalat", accountType: .savings),
        ImportProfile(id: "alliance", institution: .allianceBank, displayName: "Alliance Bank", accountType: .savings),
        ImportProfile(id: "tng", institution: .touchNGo, displayName: "Touch ’n Go eWallet", accountType: .eWallet,
                      extraSynonyms: [.description2: ["details"], .description: ["description", "transaction type"]]),
        ImportProfile(id: "grabpay", institution: .grabPay, displayName: "GrabPay", accountType: .eWallet),
        ImportProfile(id: "boost", institution: .boost, displayName: "Boost", accountType: .eWallet),
        ImportProfile(id: "shopeepay", institution: .shopeePay, displayName: "ShopeePay", accountType: .eWallet),
        ImportProfile(id: "generic", institution: .other, displayName: "Other bank or wallet (auto-detect)", accountType: .savings)
    ]

    public static func profile(id: String) -> ImportProfile? { all.first { $0.id == id } }
}
