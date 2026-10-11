import Foundation

/// One OCR'd text line (Apple Vision `VNRecognizedTextObservation` top candidate).
public struct OCRLine: Equatable, Sendable {
    public let text: String
    public let confidence: Double

    public init(_ text: String, confidence: Double = 1.0) {
        self.text = text
        self.confidence = confidence
    }
}

public enum ReceiptPaymentStatus: String, Sendable, Equatable {
    case successful, failed, pending, unknown
}

/// Structured fields pulled from a payment receipt screenshot / photo.
public struct ReceiptExtraction: Equatable, Sendable {
    public var amount: Money?
    public var amountConfidence: Double
    public var date: Date?
    public var reference: String?
    public var counterparty: String?
    public var status: ReceiptPaymentStatus
    public var channel: PaymentChannel?
    public var institution: Institution?
    /// Overall confidence: min of key-field confidences.
    public var confidence: Double {
        var values = [amountConfidence]
        if date == nil { values.append(0.5) }
        if counterparty == nil { values.append(0.6) }
        return values.min() ?? 0
    }

    public var isUsable: Bool { amount != nil && status != .failed }
}

/// Rule-based, on-device extraction from OCR text. No network, no AI service.
public struct ReceiptTextExtractor: Sendable {
    public var calendar: KLCalendar

    public init(calendar: KLCalendar = .shared) {
        self.calendar = calendar
    }

    private static let amountLabels = ["AMOUNT", "TOTAL", "JUMLAH", "AMAUN", "TOTAL AMOUNT", "TRANSFER AMOUNT", "PAYMENT AMOUNT", "YOU PAID", "PAID", "GRAND TOTAL"]
    private static let excludedAmountLabels = ["BALANCE", "BAKI", "FEE", "CAJ", "SERVICE CHARGE", "CASHBACK", "REWARD", "POINTS", "LIMIT", "SAVED", "DISCOUNT"]
    private static let referenceLabels = ["REFERENCE ID", "REFERENCE NO", "REFERENCE NUMBER", "REFERENCE", "REF NO", "REF. NO", "REF ID", "REF",
                                          "TRANSACTION ID", "TRANSACTION NO", "TRANSACTION REFERENCE", "TXN ID", "NO. RUJUKAN", "NO RUJUKAN", "RUJUKAN", "ID TRANSAKSI"]
    private static let counterpartyLabels = ["RECIPIENT NAME", "RECIPIENT", "BENEFICIARY NAME", "BENEFICIARY", "PAID TO", "MERCHANT NAME", "MERCHANT",
                                             "TRANSFER TO", "PAY TO", "NAMA PENERIMA", "PENERIMA", "TO"]
    private static let dateLabels = ["DATE & TIME", "DATE/TIME", "DATE", "TRANSACTION DATE", "TARIKH", "TARIKH & MASA", "TIME"]

    public func extract(_ lines: [OCRLine]) -> ReceiptExtraction {
        let cleaned = lines.map { OCRLine(InputSanitizer.cleanText($0.text, maxLength: 160), confidence: $0.confidence) }.filter { !$0.text.isEmpty }
        let uppers = cleaned.map { $0.text.uppercased() }
        let allText = uppers.joined(separator: "\n")

        var extraction = ReceiptExtraction(amount: nil, amountConfidence: 0, date: nil, reference: nil, counterparty: nil,
                                           status: detectStatus(allText), channel: detectChannel(allText), institution: detectInstitution(allText))
        if let (amount, confidence) = findAmount(cleaned, uppers: uppers) {
            extraction.amount = amount
            extraction.amountConfidence = confidence
        }
        extraction.date = findDate(cleaned, uppers: uppers)
        extraction.reference = labelledValue(Self.referenceLabels, in: cleaned, uppers: uppers) { value in
            let token = value.replacingOccurrences(of: " ", with: "")
            return token.count >= 6 && token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) && token.contains(where: \.isNumber) ? token : nil
        }
        extraction.counterparty = labelledValue(Self.counterpartyLabels, in: cleaned, uppers: uppers) { value in
            // Reject values that are actually amounts or account numbers.
            let digits = value.filter(\.isNumber).count
            return digits * 2 > value.count || value.uppercased().hasPrefix("RM") ? nil : InputSanitizer.cleanText(value, maxLength: 60)
        }
        return extraction
    }

    func detectStatus(_ text: String) -> ReceiptPaymentStatus {
        if ["UNSUCCESSFUL", "FAILED", "GAGAL", "DECLINED", "REJECTED", "TIDAK BERJAYA", "CANCELLED"].contains(where: text.contains) { return .failed }
        if ["PENDING", "PROCESSING", "DALAM PROSES", "IN PROGRESS"].contains(where: text.contains) { return .pending }
        if ["SUCCESSFUL", "SUCCESS", "BERJAYA", "COMPLETED", "APPROVED", "PAYMENT RECEIVED"].contains(where: text.contains) { return .successful }
        return .unknown
    }

    func detectChannel(_ text: String) -> PaymentChannel? {
        if text.contains("DUITNOW QR") || text.contains("QR PAYMENT") || text.contains("SCAN & PAY") || text.contains("SCAN AND PAY") { return .duitNowQR }
        if text.contains("DUITNOW") { return .duitNowTransfer }
        if text.contains("JOMPAY") { return .jomPay }
        if text.contains("FPX") { return .fpx }
        if text.contains("IBG") || text.contains("INSTANT TRANSFER") || text.contains("IBFT") { return .bankTransfer }
        return nil
    }

    func detectInstitution(_ text: String) -> Institution? {
        let checks: [(String, Institution)] = [("TOUCH 'N GO", .touchNGo), ("TOUCH ’N GO", .touchNGo), ("TOUCH N GO", .touchNGo), ("TNG EWALLET", .touchNGo),
                                               ("GRABPAY", .grabPay), ("BOOST", .boost), ("SHOPEEPAY", .shopeePay),
                                               ("MAYBANK", .maybank), ("MAE", .maybank), ("CIMB", .cimb), ("PUBLIC BANK", .publicBank), ("PBE", .publicBank),
                                               ("RHB", .rhb), ("HONG LEONG", .hongLeong), ("AMBANK", .ambank), ("BANK ISLAM", .bankIslam),
                                               ("MUAMALAT", .bankMuamalat), ("ALLIANCE", .allianceBank)]
        let padded = " " + text.replacingOccurrences(of: "\n", with: " ") + " "
        return checks.first { padded.contains(" \($0.0) ") || padded.contains(" \($0.0)") && $0.0.count > 4 }?.1
    }

    func findAmount(_ lines: [OCRLine], uppers: [String]) -> (Money, Double)? {
        struct Candidate { let money: Money; let score: Int; let ocrConfidence: Double; let index: Int }
        var candidates: [Candidate] = []
        for (index, upper) in uppers.enumerated() {
            for token in Self.amountTokens(in: upper) {
                guard let money = Self.parseOCRAmount(token), !money.isZero else { continue }
                var score = 0
                if token.contains("RM") || token.contains("MYR") { score += 2 }
                let context = upper + " " + (index > 0 ? uppers[index - 1] : "")
                if Self.amountLabels.contains(where: { context.contains($0) }) { score += 3 }
                if Self.excludedAmountLabels.contains(where: { upper.contains($0) }) { score -= 5 }
                if index > 0, Self.excludedAmountLabels.contains(where: { uppers[index - 1].contains($0) }), !Self.amountLabels.contains(where: { upper.contains($0) }) { score -= 4 }
                if upper.trimmingCharacters(in: .whitespaces) == token.trimmingCharacters(in: .whitespaces) { score += 1 } // amount on its own line (hero figure)
                candidates.append(Candidate(money: money, score: score, ocrConfidence: lines[index].confidence, index: index))
            }
        }
        guard let best = candidates.max(by: { ($0.score, -$0.index) < ($1.score, -$1.index) }), best.score > 0 else { return nil }
        let competing = candidates.filter { $0.score == best.score && $0.money != best.money }
        var confidence = min(best.ocrConfidence, best.score >= 5 ? 0.95 : 0.75)
        if !competing.isEmpty { confidence = min(confidence, 0.5) }
        return (best.money, confidence)
    }

    /// Finds money-looking tokens: "RM 25.00", "RM25.00", "-RM12.50", "MYR 1,234.50", "25.00".
    static func amountTokens(in line: String) -> [String] {
        let pattern = #"(?:-\s*)?(?:RM|MYR)?\s?[0-9OoIl][0-9OoIl,]*\.[0-9Oo]{2}(?![0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { Range($0.range, in: line).map { String(line[$0]) } }
    }

    /// Repairs common OCR confusions inside an amount token (O→0, I/l→1) before parsing.
    static func parseOCRAmount(_ token: String) -> Money? {
        var text = token.uppercased().replacingOccurrences(of: "MYR", with: "").replacingOccurrences(of: "RM", with: "")
        text = text.replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespaces)
        text = String(text.map { character -> Character in
            switch character {
            case "O": return "0"
            case "I", "L": return "1"
            default: return character
            }
        })
        return try? AmountParser().parse(text).money
    }

    func findDate(_ lines: [OCRLine], uppers: [String]) -> Date? {
        let parser = MalaysianDateParser(calendar: calendar)
        for (index, line) in lines.enumerated() {
            let value = Self.valueAfterLabel(Self.dateLabels, line: line.text, upper: uppers[index]) ?? line.text
            if let date = parser.parse(value) { return date }
            if Self.dateLabels.contains(where: { uppers[index].trimmingCharacters(in: CharacterSet(charactersIn: " :")) == $0 }), index + 1 < lines.count,
               let date = parser.parse(lines[index + 1].text) {
                return date
            }
        }
        return nil
    }

    /// Finds "Label: value" on one line or "Label" followed by the value on the next line.
    /// Candidates rejected by `validate` are skipped and the search continues.
    func labelledValue(_ labels: [String], in lines: [OCRLine], uppers: [String], validate: (String) -> String?) -> String? {
        for (index, line) in lines.enumerated() {
            let bare = uppers[index].trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            if labels.contains(bare) {
                if index + 1 < lines.count, let value = validate(lines[index + 1].text.trimmingCharacters(in: .whitespaces)) { return value }
                continue
            }
            if let raw = Self.valueAfterLabel(labels, line: line.text, upper: uppers[index]), let value = validate(raw) { return value }
        }
        return nil
    }

    /// "Reference ID: 2025101212345" / "Recipient  ALI BIN ABU" → value part.
    static func valueAfterLabel(_ labels: [String], line: String, upper: String) -> String? {
        for label in labels where upper.hasPrefix(label) {
            let rest = line.dropFirst(label.count)
            guard let first = rest.first, first == ":" || first == " " || first == "\t" else { continue }
            let value = rest.trimmingCharacters(in: CharacterSet(charactersIn: " :\t-"))
            if !value.isEmpty { return value }
        }
        return nil
    }
}

public enum ReceiptTransactionFactory {
    public enum FactoryError: Error, Equatable { case paymentFailed, missingAmount }

    /// Builds a confirmed record from a successful receipt. Pending receipts become `.pending`.
    public static func record(from extraction: ReceiptExtraction, accountID: UUID?, source: ImportSource = .receiptImage,
                              engine: CategoryEngine = CategoryEngine(), rules: [MerchantRule] = [], now: Date = Date()) throws -> TransactionRecord {
        guard extraction.status != .failed else { throw FactoryError.paymentFailed }
        guard let amount = extraction.amount else { throw FactoryError.missingAmount }
        let categorisation = engine.categorise(merchant: extraction.counterparty, description: extraction.counterparty ?? "", rules: rules)
        var flags: Set<ReviewFlag> = []
        if extraction.counterparty == nil { flags.insert(.merchantMissing) }
        if extraction.status == .unknown { flags.insert(.unconfirmedPayment) }
        if categorisation.confidence < engine.reviewThreshold { flags.insert(.lowConfidenceCategory) }
        return TransactionRecord(
            accountID: accountID,
            amount: amount,
            direction: .outflow,
            kind: categorisation.kindHint ?? .expense,
            merchant: extraction.counterparty.map(MerchantNormalizer.displayName),
            transactionDescription: extraction.counterparty ?? "Receipt",
            transactionDate: extraction.date ?? now,
            channel: extraction.channel ?? (extraction.institution?.isEWallet == true ? .eWallet : .other),
            categoryID: categorisation.categoryID,
            status: extraction.status == .successful ? .confirmed : .pending,
            source: source,
            externalReference: extraction.reference,
            confidence: extraction.confidence,
            flags: flags,
            createdAt: now,
            updatedAt: now
        )
    }
}
