import Foundation

/// Outcome of parsing a statement. Nothing is persisted here: the app shows a preview,
/// runs reconciliation, and only then saves.
public struct ImportResult: Sendable {
    public struct SkippedRow: Equatable, Sendable {
        public let line: Int
        public let reason: String
    }

    public var transactions: [TransactionRecord]
    public var skipped: [SkippedRow]
    public var warnings: [String]
    public var detectedColumns: [StatementColumn: Int]

    public var isEmpty: Bool { transactions.isEmpty }
}

public enum StatementImportError: Error, Equatable, Sendable {
    case noHeaderRow
    case missingColumns([StatementColumn])
    case noTransactions
}

/// Context shared by all statement parsers.
public struct ImportContext: Sendable {
    public var account: Account?
    public var profile: ImportProfile
    public var source: ImportSource
    public var rules: [MerchantRule]
    public var engine: CategoryEngine
    public var classifier: TransferClassifier
    /// Used to infer missing years ("12 OCT").
    public var statementDate: Date?
    public var now: Date

    public init(account: Account?, profile: ImportProfile, source: ImportSource, rules: [MerchantRule] = [],
                engine: CategoryEngine = CategoryEngine(), classifier: TransferClassifier = TransferClassifier(),
                statementDate: Date? = nil, now: Date = Date()) {
        self.account = account
        self.profile = profile
        self.source = source
        self.rules = rules
        self.engine = engine
        self.classifier = classifier
        self.statementDate = statementDate
        self.now = now
    }
}

/// Builds normalised records from parsed statement rows. Shared by CSV and PDF-text parsers so that
/// classification, categorisation and fingerprints are identical whichever format was imported.
struct StatementRowBuilder {
    let context: ImportContext
    private var occurrences: [String: Int] = [:]

    init(context: ImportContext) {
        self.context = context
    }

    func isSummaryRow(_ description: String) -> Bool {
        let upper = TransferClassifier.normalize(description).trimmingCharacters(in: .whitespaces)
        return context.profile.summaryRowMarkers.contains { upper == $0 || upper.hasPrefix($0 + " ") || upper.hasPrefix($0 + ":") }
    }

    mutating func build(date: Date, postingDate: Date?, description rawDescription: String, amount: Money,
                        direction: TransactionDirection, reference: String?) -> TransactionRecord {
        let description = InputSanitizer.cleanText(rawDescription, maxLength: 200)
        let reference = InputSanitizer.cleanOptional(reference, maxLength: 64)
        let classification = context.classifier.classify(description: description, direction: direction, accountType: context.account?.type ?? context.profile.accountType)
        let categorisation = context.engine.categorise(merchant: nil, description: description, rules: context.rules)

        var kind = classification.kind
        // Merchant-dictionary kind hints (e.g. "TNG RELOAD") override generic defaults but not keyword rules.
        if let hint = categorisation.kindHint, classification.confidence < 0.8, hint.expectedDirection == nil || hint.expectedDirection == direction {
            kind = hint
        }

        var flags: Set<ReviewFlag> = []
        let categoryID: String?
        switch kind {
        case .expense, .fee, .refund, .reversal:
            categoryID = kind == .fee && categorisation.layer == .fallback ? BuiltInCategory.debtInterestFees.id : categorisation.categoryID
            if categorisation.confidence < context.engine.reviewThreshold { flags.insert(.lowConfidenceCategory) }
        case .transfer, .creditCardRepayment, .walletTopUp:
            categoryID = BuiltInCategory.transfers.id
        case .income, .debtRepayment:
            categoryID = nil
        }
        if classification.confidence < 0.5 { flags.insert(.directionUncertain) }

        let baseKey = "\(date.timeIntervalSince1970)|\(amount.minorUnits)|\(direction)|\(MerchantNormalizer.key(description))"
        let occurrence = occurrences[baseKey, default: 0]
        occurrences[baseKey] = occurrence + 1
        let fingerprint = Fingerprint.statementRow(accountID: context.account?.id, date: date, direction: direction, amount: amount,
                                                   description: description, reference: reference, occurrence: occurrence)
        let merchant = categorisation.canonicalMerchant ?? MerchantNormalizer.displayName(description)

        return TransactionRecord(
            accountID: context.account?.id,
            amount: amount,
            direction: direction,
            kind: kind,
            merchant: merchant.isEmpty ? nil : merchant,
            transactionDescription: description,
            transactionDate: date,
            postingDate: postingDate,
            channel: Self.inferChannel(description, accountType: context.account?.type ?? context.profile.accountType),
            categoryID: categoryID,
            status: .confirmed,
            source: context.source,
            externalReference: reference,
            confidence: min(classification.confidence, max(categorisation.confidence, 0.5)),
            flags: flags,
            importFingerprint: fingerprint,
            createdAt: context.now,
            updatedAt: context.now
        )
    }

    static func inferChannel(_ description: String, accountType: AccountType) -> PaymentChannel {
        let text = description.uppercased()
        if text.contains("DUITNOW QR") || text.contains("QR PAYMENT") || text.contains("QRPAY") { return .duitNowQR }
        if text.contains("DUITNOW") { return .duitNowTransfer }
        if text.contains("FPX") { return .fpx }
        if text.contains("JOMPAY") { return .jomPay }
        if text.contains("ATM") || text.contains("CASH WITHDRAWAL") || text.contains("PENGELUARAN TUNAI") { return .atm }
        if text.contains("IBG") || text.contains("IBFT") || text.contains("INSTANT TRANSFER") || text.contains("FUND TRANSFER") { return .bankTransfer }
        if text.contains("DIRECT DEBIT") || text.contains("AUTODEBIT") || text.contains("STANDING INSTRUCTION") { return .directDebit }
        if text.contains("APPLE PAY") { return .applePay }
        if accountType == .eWallet { return .eWallet }
        if accountType == .creditCard || text.contains("POS ") || text.contains("VISA") || text.contains("MASTERCARD") || text.contains("DEBIT CARD") { return .card }
        return .other
    }
}

/// CSV statement importer driven by `ImportProfile` header synonyms.
public struct CSVStatementImporter: Sendable {
    public init() {}

    public func parse(_ text: String, context: ImportContext) throws -> ImportResult {
        let rows = CSVReader.rows(text)
        guard let (headerIndex, columns) = Self.detectHeader(rows, profile: context.profile) else { throw StatementImportError.noHeaderRow }

        var missing: [StatementColumn] = []
        if columns[.date] == nil { missing.append(.date) }
        if columns[.description] == nil { missing.append(.description) }
        if columns[.amount] == nil && columns[.debit] == nil && columns[.credit] == nil { missing.append(.amount) }
        guard missing.isEmpty else { throw StatementImportError.missingColumns(missing) }

        let dateParser = MalaysianDateParser(referenceDate: context.statementDate ?? context.now)
        let amountParser = AmountParser(currency: context.account?.currency ?? .myr)
        var builder = StatementRowBuilder(context: context)
        var result = ImportResult(transactions: [], skipped: [], warnings: [], detectedColumns: columns)
        if !context.profile.layoutVerified {
            result.warnings.append("The \(context.profile.displayName) layout was matched by column names. Check the preview before saving.")
        }

        let convention: AmountConvention = {
            if context.profile.convention != .auto { return context.profile.convention }
            if columns[.debit] != nil || columns[.credit] != nil { return .debitCreditColumns }
            return (context.account?.type ?? context.profile.accountType) == .creditCard ? .signedPositiveIsOutflow : .signedNegativeIsOutflow
        }()

        for (offset, row) in rows.enumerated() where offset > headerIndex {
            let line = offset + 1
            func cell(_ column: StatementColumn) -> String? {
                guard let index = columns[column], index < row.count else { return nil }
                let value = row[index].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }

            guard let dateText = cell(.date), let date = dateParser.parse(dateText) else {
                result.skipped.append(.init(line: line, reason: "No transaction date"))
                continue
            }
            var description = cell(.description) ?? ""
            if let extra = cell(.description2), !description.contains(extra) {
                description = description.isEmpty ? extra : description + " " + extra
            }
            if builder.isSummaryRow(description) {
                result.skipped.append(.init(line: line, reason: "Balance or summary line"))
                continue
            }
            if let status = cell(.status)?.uppercased(), context.profile.failedStatusMarkers.contains(where: { status.contains($0) }) {
                result.skipped.append(.init(line: line, reason: "Transaction status: \(status.capitalized)"))
                continue
            }

            let amountAndDirection: (Money, TransactionDirection)?
            do {
                amountAndDirection = try Self.extractAmount(cell: cell, convention: convention, parser: amountParser)
            } catch {
                result.skipped.append(.init(line: line, reason: "Unreadable amount"))
                continue
            }
            guard let (amount, direction) = amountAndDirection else {
                result.skipped.append(.init(line: line, reason: cell(.balance) != nil ? "Balance-only line" : "No amount"))
                continue
            }

            let postingDate = cell(.postingDate).flatMap(dateParser.parse)
            result.transactions.append(builder.build(date: date, postingDate: postingDate, description: description,
                                                     amount: amount, direction: direction, reference: cell(.reference)))
        }

        guard !result.transactions.isEmpty else { throw StatementImportError.noTransactions }
        return result
    }

    static func extractAmount(cell: (StatementColumn) -> String?, convention: AmountConvention, parser: AmountParser) throws -> (Money, TransactionDirection)? {
        switch convention {
        case .debitCreditColumns, .auto:
            if let debit = cell(.debit) {
                let parsed = try parser.parse(debit)
                if !parsed.money.isZero { return (parsed.money, parsed.isNegative && parsed.marker == nil ? .inflow : .outflow) }
            }
            if let credit = cell(.credit) {
                let parsed = try parser.parse(credit)
                if !parsed.money.isZero { return (parsed.money, parsed.isNegative && parsed.marker == nil ? .outflow : .inflow) }
            }
            if let amount = cell(.amount) {
                let parsed = try parser.parse(amount)
                guard !parsed.money.isZero else { return nil }
                return (parsed.money, parsed.isNegative ? .outflow : .inflow)
            }
            return nil
        case .signedNegativeIsOutflow, .signedPositiveIsOutflow:
            guard let amount = cell(.amount) ?? cell(.debit) ?? cell(.credit) else { return nil }
            let parsed = try parser.parse(amount)
            guard !parsed.money.isZero else { return nil }
            if let marker = parsed.marker { return (parsed.money, marker == .debit ? .outflow : .inflow) }
            let negativeIsOut = convention == .signedNegativeIsOutflow
            return (parsed.money, parsed.isNegative == negativeIsOut ? .outflow : .inflow)
        }
    }

    /// Finds the header row (first 40 rows) and maps columns, preferring exact synonym matches.
    static func detectHeader(_ rows: [[String]], profile: ImportProfile) -> (Int, [StatementColumn: Int])? {
        func normalize(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "_", with: " ")
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " :*"))
        }
        for (index, row) in rows.prefix(40).enumerated() {
            let headers = row.map(normalize)
            var mapping: [StatementColumn: Int] = [:]
            var used = Set<Int>()
            // Pass 1: exact matches, in synonym priority order.
            for column in StatementColumn.allCases {
                for synonym in profile.headerSynonyms[column] ?? [] {
                    if let position = headers.indices.first(where: { headers[$0] == synonym && !used.contains($0) }) {
                        mapping[column] = position; used.insert(position); break
                    }
                }
            }
            // Pass 2: containment for longer synonyms ("Transaction Date (DD/MM/YYYY)").
            for column in StatementColumn.allCases where mapping[column] == nil {
                for synonym in profile.headerSynonyms[column] ?? [] where synonym.count >= 4 {
                    if let position = headers.indices.first(where: { headers[$0].hasPrefix(synonym) && !used.contains($0) }) {
                        mapping[column] = position; used.insert(position); break
                    }
                }
            }
            let hasAmount = mapping[.amount] != nil || mapping[.debit] != nil || mapping[.credit] != nil
            if mapping[.date] != nil && mapping[.description] != nil && hasAmount {
                return (index, mapping)
            }
        }
        return nil
    }
}
