import Foundation

/// Parses text extracted from text-based PDF statements (PDFKit on device).
///
/// Strategy, designed to be layout-tolerant rather than bank-specific:
/// - A transaction row starts with a date; following lines without a date continue its description.
/// - Trailing money tokens (must have 2 decimals) are the amount and, if present, the running balance.
/// - Direction comes from explicit markers ("45.50-", "DR", "CR", "+") or, failing that, from the change
///   in running balance. If neither is available the row is flagged `directionUncertain`.
/// Scanned (image-only) PDFs produce no text and must go through OCR instead.
public struct StatementTextParser: Sendable {
    public init() {}

    struct MoneyToken {
        let money: Money
        let marker: TransactionDirection?
    }

    public func parse(_ text: String, context: ImportContext) throws -> ImportResult {
        let dateParser = MalaysianDateParser(referenceDate: context.statementDate ?? context.now)
        let amountParser = AmountParser(currency: context.account?.currency ?? .myr)
        var builder = StatementRowBuilder(context: context)
        var result = ImportResult(transactions: [], skipped: [], warnings: [], detectedColumns: [:])

        struct Pending {
            var line: Int
            var date: Date
            var description: String
            var amount: Money
            var direction: TransactionDirection?
            var balance: Money?
        }
        var pending: Pending?
        var previousBalance: Money?

        func flush() {
            guard var row = pending else { return }
            pending = nil
            if builder.isSummaryRow(row.description) {
                previousBalance = row.balance ?? row.amount
                result.skipped.append(.init(line: row.line, reason: "Balance or summary line"))
                return
            }
            if row.direction == nil, let balance = row.balance, let previous = previousBalance {
                let delta = balance - previous
                if delta.magnitude == row.amount { row.direction = delta.isNegative ? .outflow : .inflow }
            }
            if let balance = row.balance { previousBalance = balance }
            var record = builder.build(date: row.date, postingDate: nil, description: row.description, amount: row.amount,
                                       direction: row.direction ?? .outflow, reference: nil)
            if row.direction == nil {
                record.flags.insert(.directionUncertain)
                record.confidence = min(record.confidence, 0.4)
            }
            result.transactions.append(record)
        }

        let lines = text.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !line.isEmpty else { continue }

            if let (date, remainder) = dateParser.startsWithDate(line) {
                flush()
                var tokens = remainder.split(separator: " ").map(String.init)
                // Drop a leading time ("14:32") or a second (posting) date column.
                if let first = tokens.first, first.contains(":") && first.count <= 8 { tokens.removeFirst() }
                if let first = tokens.first, dateParser.parse(first) != nil, first.contains("/") || first.contains("-") { tokens.removeFirst() }

                var moneyTokens: [MoneyToken] = []
                while let last = tokens.last {
                    var token = last
                    var marker: TransactionDirection?
                    let upper = token.uppercased()
                    if upper == "DR" || upper == "CR", tokens.count >= 2 {
                        marker = upper == "DR" ? .outflow : .inflow
                        tokens.removeLast()
                        token = tokens.last!
                    }
                    guard let parsed = Self.moneyToken(token, parser: amountParser) else {
                        if marker != nil { tokens.append(upper) } // put back the DR/CR we consumed
                        break
                    }
                    tokens.removeLast()
                    moneyTokens.insert(MoneyToken(money: parsed.money, marker: marker ?? parsed.marker), at: 0)
                    if moneyTokens.count == 3 { break }
                }
                guard let amountToken = moneyTokens.first else {
                    // Dated line without an amount: may be a header or a balance carried forward.
                    pending = nil
                    result.skipped.append(.init(line: index + 1, reason: "No amount on dated line"))
                    continue
                }
                // With 3 tokens assume debit/credit/balance layout where one of the first two is the amount.
                var amount = amountToken
                var balance: Money? = moneyTokens.count >= 2 ? moneyTokens.last!.money : nil
                if moneyTokens.count == 3 {
                    amount = moneyTokens[0].money.isZero ? MoneyToken(money: moneyTokens[1].money, marker: .inflow) : MoneyToken(money: moneyTokens[0].money, marker: .outflow)
                    balance = moneyTokens[2].money
                }
                guard !amount.money.isZero else {
                    result.skipped.append(.init(line: index + 1, reason: "Zero amount"))
                    continue
                }
                pending = Pending(line: index + 1, date: date, description: tokens.joined(separator: " "),
                                  amount: amount.money, direction: amount.marker, balance: balance)
            } else if pending != nil {
                // Continuation of the previous description (common for DuitNow/IBG recipient lines).
                let upper = line.uppercased()
                let isFooter = upper.hasPrefix("PAGE ") || upper.hasPrefix("MUKA SURAT") || upper.contains("ENDING BALANCE") || upper.contains("NOTA")
                if !isFooter, line.count <= 80 {
                    pending!.description += " " + line
                }
            } else if let balance = Self.balanceLine(line, parser: amountParser) {
                previousBalance = balance
            }
        }
        flush()

        let uncertainCount = result.transactions.filter { $0.flags.contains(.directionUncertain) }.count
        if uncertainCount > 0 {
            result.warnings.append("\(uncertainCount) transaction(s) need their direction or type confirmed.")
        }
        guard !result.transactions.isEmpty else { throw StatementImportError.noTransactions }
        return result
    }

    static func moneyToken(_ token: String, parser: AmountParser) -> (money: Money, marker: TransactionDirection?)? {
        var text = token
        var marker: TransactionDirection?
        if text.hasSuffix("-") { marker = .outflow; text.removeLast() } else if text.hasSuffix("+") { marker = .inflow; text.removeLast() }
        if text.hasPrefix("(") && text.hasSuffix(")") { marker = .outflow; text = String(text.dropFirst().dropLast()) }
        if text.hasPrefix("-") { marker = .outflow; text.removeFirst() }
        // Require exactly two decimals so references/IDs are not mistaken for amounts.
        guard let dot = text.lastIndex(of: "."), text.distance(from: dot, to: text.endIndex) == 3 else { return nil }
        guard let parsed = try? parser.parse(text) else { return nil }
        return (parsed.money, marker)
    }

    /// "OPENING BALANCE 1,234.56" / "BAKI MULA 1,234.56" without a date.
    static func balanceLine(_ line: String, parser: AmountParser) -> Money? {
        let upper = line.uppercased()
        guard ["OPENING BALANCE", "BEGINNING BALANCE", "BALANCE B/F", "BAKI MULA", "BALANCE FROM PREVIOUS STATEMENT"].contains(where: upper.hasPrefix),
              let last = line.split(separator: " ").last else { return nil }
        return moneyToken(String(last), parser: parser)?.money
    }
}
