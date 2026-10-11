import Foundation

/// Raw values delivered by the "Log Payment in Kira" App Intent. Everything is optional because
/// the Wallet "Transaction" automation does not always populate fields (developers have reported
/// blank merchants and 0.0 amounts), and users may build Shortcuts by hand.
public struct ShortcutTransactionInput: Codable, Hashable, Sendable {
    /// Amount as delivered: Shortcuts may pass "RM12.50", "12.50", "12,50" or a number.
    public var amountText: String?
    public var merchant: String?
    /// Wallet "Card or Pass" name, e.g. "Maybank Visa Debit".
    public var cardName: String?
    public var date: Date?
    public var reference: String?
    /// ISO currency if the Shortcut provides it separately.
    public var currencyCode: String?
    public var notes: String?

    public init(amountText: String? = nil, merchant: String? = nil, cardName: String? = nil, date: Date? = nil,
                reference: String? = nil, currencyCode: String? = nil, notes: String? = nil) {
        self.amountText = amountText
        self.merchant = merchant
        self.cardName = cardName
        self.date = date
        self.reference = reference
        self.currencyCode = currencyCode
        self.notes = notes
    }
}

/// Envelope written to the protected capture inbox when the intent runs while the main store is
/// unavailable (device locked with Data Protection `complete`). Drained on next app unlock.
public struct CaptureInboxItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var receivedAt: Date
    public var input: ShortcutTransactionInput

    public init(id: UUID = UUID(), receivedAt: Date = Date(), input: ShortcutTransactionInput) {
        self.id = id
        self.receivedAt = receivedAt
        self.input = input
    }
}

public enum ShortcutCaptureOutcome: Equatable, Sendable {
    case created(TransactionRecord)
    /// The same automation fired again for the same payment (repeat run, retries).
    case duplicate(existingID: UUID)
    case rejected(String)
}

/// Validates and normalises Shortcut input into a `.pending` record. A Wallet tap is evidence of
/// an authorisation, not a settled payment — the record stays pending until confirmed or matched
/// against a statement.
public struct ShortcutCaptureProcessor: Sendable {
    /// Repeat events for the same card/merchant/amount within this window are treated as one payment.
    public var duplicateWindow: TimeInterval
    public var engine: CategoryEngine

    public init(duplicateWindow: TimeInterval = 180, engine: CategoryEngine = CategoryEngine()) {
        self.duplicateWindow = duplicateWindow
        self.engine = engine
    }

    public func process(_ input: ShortcutTransactionInput, receivedAt: Date, accounts: [Account], existing: [TransactionRecord],
                        rules: [MerchantRule] = []) -> ShortcutCaptureOutcome {
        let merchant = InputSanitizer.cleanOptional(input.merchant, maxLength: 80)
        let cardName = InputSanitizer.cleanOptional(input.cardName, maxLength: 80)
        let reference = InputSanitizer.cleanOptional(input.reference, maxLength: 64)
        let notes = InputSanitizer.cleanOptional(input.notes, maxLength: 500)
        let date = Self.plausibleDate(input.date, receivedAt: receivedAt)

        var flags: Set<ReviewFlag> = [.unconfirmedPayment]
        var amount = Money.zero(.myr)
        let declaredCurrency = input.currencyCode.map { CurrencyCode(rawValue: InputSanitizer.cleanText($0, maxLength: 3)) }
        if let text = InputSanitizer.cleanOptional(input.amountText, maxLength: 32) {
            switch Self.parseAmount(text, declared: declaredCurrency) {
            case .success(let money):
                amount = money
            case .failure(let reason):
                return .rejected(reason)
            }
        }
        if amount.isZero { flags.insert(.amountMissing) }
        if amount.currency != .myr { flags.insert(.foreignCurrency) }
        if merchant == nil { flags.insert(.merchantMissing) }

        let account = Self.matchAccount(cardName: cardName, accounts: accounts)
        let key = Self.dedupeKey(cardName: cardName, merchant: merchant, amount: amount, date: date, window: duplicateWindow)

        if let duplicate = existing.first(where: { record in
            record.source == .appleShortcut && record.status != .superseded &&
                (record.importFingerprint == key ||
                 (reference != nil && record.externalReference == reference) ||
                 (record.amount == amount && !amount.isZero && TextSimilarity.merchant(record.merchant, merchant) >= 0.85 &&
                  record.accountID == account?.id && abs(record.transactionDate.timeIntervalSince(date)) <= duplicateWindow))
        }) {
            return .duplicate(existingID: duplicate.id)
        }

        let categorisation = engine.categorise(merchant: merchant, description: merchant ?? "", rules: rules)
        if categorisation.confidence < engine.reviewThreshold { flags.insert(.lowConfidenceCategory) }

        let record = TransactionRecord(
            accountID: account?.id,
            amount: amount,
            direction: .outflow,
            kind: categorisation.kindHint ?? .expense,
            merchant: categorisation.canonicalMerchant ?? merchant.map(MerchantNormalizer.displayName),
            transactionDescription: [merchant, cardName].compactMap { $0 }.joined(separator: " · "),
            transactionDate: date,
            channel: .applePay,
            categoryID: categorisation.categoryID,
            status: .pending,
            source: .appleShortcut,
            externalReference: reference,
            confidence: amount.isZero ? 0.3 : 0.8,
            flags: flags,
            notes: notes,
            importFingerprint: key,
            createdAt: receivedAt,
            updatedAt: receivedAt
        )
        return .created(record)
    }

    /// Dates far in the future or past are almost certainly bad input; fall back to the receive time.
    static func plausibleDate(_ date: Date?, receivedAt: Date) -> Date {
        guard let date else { return receivedAt }
        let delta = date.timeIntervalSince(receivedAt)
        return (delta > 600 || delta < -45 * 86_400) ? receivedAt : date
    }

    enum AmountOutcome { case success(Money), failure(String) }

    static func parseAmount(_ text: String, declared: CurrencyCode?) -> AmountOutcome {
        let currency = declared ?? .myr
        do {
            let result = try AmountParser(currency: currency, lenientDecimalComma: true).parse(text)
            return .success(result.money)
        } catch AmountParser.ParseError.currencyMismatch(let code) {
            if let result = try? AmountParser(currency: CurrencyCode(rawValue: code), lenientDecimalComma: true).parse(text) {
                return .success(result.money)
            }
            return .failure("Unsupported currency in amount")
        } catch AmountParser.ParseError.empty {
            return .success(.zero(currency))
        } catch {
            // Unknown currency symbol prefixes ("€12.00"): keep the digits, flag as foreign.
            let digits = text.filter { $0.isNumber || $0 == "." || $0 == "," }
            if !digits.isEmpty, let result = try? AmountParser(currency: CurrencyCode(rawValue: "XXX"), lenientDecimalComma: true).parse(digits) {
                return .success(result.money)
            }
            return .failure("Amount “\(text)” could not be read")
        }
    }

    static func matchAccount(cardName: String?, accounts: [Account]) -> Account? {
        guard let cardName = cardName?.uppercased(), !cardName.isEmpty else { return nil }
        let active = accounts.filter { !$0.isArchived }
        if let exact = active.first(where: { $0.walletCardNames.contains { $0.uppercased() == cardName } }) { return exact }
        let byLastFour = active.filter { account in account.lastFour.map { $0.count == 4 && cardName.contains($0) } ?? false }
        if byLastFour.count == 1 { return byLastFour[0] }
        let byName = active.filter { cardName.contains($0.name.uppercased()) || $0.walletCardNames.contains { cardName.contains($0.uppercased()) } }
        return byName.count == 1 ? byName[0] : nil
    }

    static func dedupeKey(cardName: String?, merchant: String?, amount: Money, date: Date, window: TimeInterval) -> String {
        let bucket = Int(date.timeIntervalSince1970 / max(window, 1))
        return Fingerprint.fnv1a(["shortcut", cardName?.uppercased() ?? "", MerchantNormalizer.key(merchant ?? ""), "\(amount.minorUnits)\(amount.currency.rawValue)", "\(bucket)"].joined(separator: "|"))
    }
}
