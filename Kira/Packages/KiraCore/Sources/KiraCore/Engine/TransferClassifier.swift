import Foundation

/// Infers the economic `TransactionKind` from statement text, and pairs transfer legs
/// between accounts the user owns. Classification is a suggestion with a confidence;
/// user-set kinds always win.
public struct TransferClassifier: Sendable {
    public struct Classification: Equatable, Sendable {
        public let kind: TransactionKind
        public let confidence: Double
        public let reason: String
    }

    public init() {}

    // Ordered: first match wins. Patterns are matched against an uppercased, whitespace-collapsed description.
    private static let rules: [(patterns: [String], kind: TransactionKind, direction: TransactionDirection?, confidence: Double, reason: String)] = [
        (["REVERSAL", "REVERSED", "PEMBATALAN", "CHARGEBACK"], .reversal, .inflow, 0.9, "Reversal keyword"),
        (["REFUND", "PULANGAN WANG", "BAYARAN BALIK"], .refund, .inflow, 0.9, "Refund keyword"),
        (["PAYMENT - THANK YOU", "PAYMENT RECEIVED", "PAYMENT-THANK YOU", "CC PAYMENT", "CC PYMT", "CARD PAYMENT", "CREDIT CARD PAYMENT", "BAYARAN KAD KREDIT", "PYMT TO CC"],
         .creditCardRepayment, nil, 0.85, "Credit card repayment keyword"),
        (["TNG RELOAD", "TNG EWALLET RELOAD", "TOUCH N GO RELOAD", "TOUCH 'N GO RELOAD", "GRABPAY TOP UP", "GRABPAY TOPUP", "GRAB TOP UP",
          "BOOST RELOAD", "BOOST TOP UP", "SHOPEEPAY TOP UP", "SHOPEEPAY TOPUP", "EWALLET RELOAD", "E-WALLET RELOAD", "WALLET TOP UP", "RELOAD EWALLET"],
         .walletTopUp, .outflow, 0.85, "E-wallet top-up keyword"),
        (["LATE CHARGE", "LATE PAYMENT", "FINANCE CHARGE", "INTEREST CHARGE", "SERVICE CHARGE", "ANNUAL FEE", "CAJ ", "STAMP DUTY", "DUTI SETEM",
          "OVERLIMIT", "CASH ADVANCE FEE", "BANK CHARGE", "SMS ALERT FEE", "IBG FEE", "TRANSACTION FEE"],
         .fee, .outflow, 0.8, "Fee keyword"),
        (["SALARY", "GAJI", "PAYROLL", "SAL CR", "BONUS"], .income, .inflow, 0.85, "Salary keyword"),
        (["PTPTN", "HOUSING LOAN", "PINJAMAN PERUMAHAN", "HIRE PURCHASE", "SEWA BELI", "PERSONAL LOAN", "PINJAMAN PERIBADI", "LOAN REPAYMENT", "INSTALMENT", "ANSURAN"],
         .debtRepayment, .outflow, 0.7, "Loan repayment keyword"),
        (["OWN ACCOUNT", "OWN ACC", "TRANSFER TO OWN", "FUND TRANSFER TO SAV", "AKAUN SENDIRI"], .transfer, nil, 0.75, "Own-account transfer keyword"),
        (["INTEREST CREDIT", "HIBAH", "PROFIT PAID", "DIVIDEND"], .income, .inflow, 0.7, "Interest/dividend credit")
    ]

    /// Classifies a statement line. `accountType` lets card-side payments be recognised.
    public func classify(description: String, direction: TransactionDirection, accountType: AccountType?) -> Classification {
        let text = Self.normalize(description)
        for rule in Self.rules where rule.patterns.contains(where: { text.contains($0) }) {
            if let expected = rule.direction, expected != direction {
                continue
            }
            return Classification(kind: rule.kind, confidence: rule.confidence, reason: rule.reason)
        }
        // A credit on a credit-card account without other signals is almost always a repayment.
        if accountType == .creditCard && direction == .inflow {
            return Classification(kind: .creditCardRepayment, confidence: 0.6, reason: "Credit on card account")
        }
        // A debit on an e-wallet statement is spending; a credit is usually a top-up received.
        if accountType == .eWallet && direction == .inflow {
            return Classification(kind: .transfer, confidence: 0.5, reason: "Credit on e-wallet (likely top-up)")
        }
        return direction == .outflow
            ? Classification(kind: .expense, confidence: 0.6, reason: "Default for debits")
            : Classification(kind: .income, confidence: 0.4, reason: "Default for credits")
    }

    static func normalize(_ text: String) -> String {
        text.uppercased()
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ") + " "
    }

    // MARK: Transfer pairing

    public struct TransferPair: Equatable, Sendable {
        public let outflowID: UUID
        public let inflowID: UUID
        public let suggestedKind: TransactionKind
    }

    /// Finds outflow/inflow pairs of identical amount between two different owned accounts within
    /// `maxDays`. Only unambiguous one-to-one matches are returned; ambiguous candidates are left alone.
    public func pairTransfers(_ records: [TransactionRecord], accounts: [Account], maxDays: Int = 2,
                              calendar: KLCalendar = .shared) -> [TransferPair] {
        let accountTypes = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.type) })
        let excludedKinds: Set<TransactionKind> = [.refund, .reversal, .fee]
        let eligible = records.filter {
            $0.accountID != nil && $0.status != .superseded && $0.status != .draft && !excludedKinds.contains($0.kind)
        }
        let outflows = eligible.filter { $0.direction == .outflow }
        let inflows = eligible.filter { $0.direction == .inflow }

        var candidatesForOutflow: [UUID: [TransactionRecord]] = [:]
        var candidatesForInflow: [UUID: [UUID]] = [:]
        for out in outflows {
            let matches = inflows.filter {
                $0.accountID != out.accountID && $0.amount == out.amount &&
                abs(calendar.dayDistance(from: out.transactionDate, to: $0.transactionDate)) <= maxDays
            }
            candidatesForOutflow[out.id] = matches
            for match in matches { candidatesForInflow[match.id, default: []].append(out.id) }
        }

        var pairs: [TransferPair] = []
        for out in outflows {
            guard let matches = candidatesForOutflow[out.id], matches.count == 1, let inflow = matches.first,
                  candidatesForInflow[inflow.id]?.count == 1 else { continue }
            let kind: TransactionKind
            switch inflow.accountID.flatMap({ accountTypes[$0] }) {
            case .creditCard?: kind = .creditCardRepayment
            case .eWallet?: kind = .walletTopUp
            case .loan?: kind = .debtRepayment
            default: kind = .transfer
            }
            pairs.append(TransferPair(outflowID: out.id, inflowID: inflow.id, suggestedKind: kind))
        }
        return pairs
    }
}
