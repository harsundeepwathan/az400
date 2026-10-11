import Foundation

/// Parsed DuitNow / EMV merchant-presented QR. Field meanings follow PayNet's DuitNow QR
/// "QR Data Object" specification (Merchant-Presented Mode).
///
/// IMPORTANT: this describes what the merchant *asked* to be paid. It is never evidence that a
/// payment happened. Kira only ever creates a `.draft` transaction from it.
public struct DuitNowQRPayload: Equatable, Sendable {
    public enum Initiation: String, Sendable { case staticQR = "11", dynamicQR = "12" }

    public let payloadFormat: String
    public let initiation: Initiation
    /// True when a merchant account template carries the Malaysian DuitNow AID (A0000006150001).
    public let isDuitNow: Bool
    public let applicationIdentifier: String?
    public let acquirerID: String?
    /// Merchant/recipient QR ID (tag 26/02).
    public let qrID: String?
    public let merchantDescriptor: String?
    public let merchantCategoryCode: String
    public let currency: CurrencyCode?
    public let numericCurrency: String
    /// nil for QR codes where the payer enters the amount.
    public let amount: Money?
    public let tipIndicator: String?
    public let convenienceFeeFixed: Money?
    public let convenienceFeePercentage: Decimal?
    public let countryCode: String
    public let merchantName: String
    public let merchantCity: String
    public let postalCode: String?
    public let billNumber: String?
    public let referenceLabel: String?
    public let storeLabel: String?
    public let terminalLabel: String?
    public let purpose: String?
    /// JomPAY / bill reference (tag 62/90).
    public let referenceNumber: String?
    public let alternateMerchantName: String?
    /// Unknown or proprietary tags preserved for diagnostics.
    public let unrecognisedTags: [String]
    public let warnings: [DuitNowQRParser.Warning]

    /// Person-to-person QR (MCC 0000) — a transfer to an individual, not a merchant purchase.
    public var isPersonToPerson: Bool { merchantCategoryCode == "0000" }
    /// Amount that the payer must enter themselves.
    public var requiresPayerAmount: Bool { amount == nil }
}

public struct DuitNowQRParser: Sendable {
    public enum ParseError: Error, Equatable, Sendable {
        case empty
        case notEMVQR
        case malformed(String)
        case missingMandatoryField(String)
        case crcMissing
        case crcMismatch(expected: String, actual: String)
        case invalidAmount(String)
        case payloadTooLong
    }

    public enum Warning: String, Equatable, Sendable {
        case notDuitNow
        case nonMalaysianCountry
        case unsupportedCurrency
        case amountOnStaticQR
        case dynamicWithoutAmount
        case merchantNameTruncated
        case invalidPostalCode
    }

    /// EMV MPM payloads are at most 512 characters.
    public static let maximumLength = 512
    public static let duitNowAID = "A0000006150001"

    public var validateCRC: Bool

    public init(validateCRC: Bool = true) {
        self.validateCRC = validateCRC
    }

    public func parse(_ rawPayload: String) throws -> DuitNowQRPayload {
        let payload = rawPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { throw ParseError.empty }
        guard payload.count <= Self.maximumLength else { throw ParseError.payloadTooLong }
        // Tag 00 (Payload Format Indicator) is "01" in EMV QRCPS; PayNet's DuitNow examples use "02".
        guard payload.hasPrefix("000201") || payload.hasPrefix("000202") else { throw ParseError.notEMVQR }

        let objects: [TLVObject]
        do {
            objects = try EMVTLV.parse(payload)
        } catch {
            throw ParseError.malformed(String(describing: error))
        }
        var fields: [String: String] = [:]
        for object in objects { fields[object.id] = object.value }

        // CRC must be the final object, length 4, computed over everything up to and including "6304".
        guard let last = objects.last, last.id == "63" else { throw ParseError.crcMissing }
        guard last.value.count == 4 else { throw ParseError.malformed("CRC length") }
        if validateCRC {
            let covered = String(payload.dropLast(4))
            let expected = CRC16CCITT.hex(covered)
            guard expected == last.value.uppercased() else {
                throw ParseError.crcMismatch(expected: expected, actual: last.value.uppercased())
            }
        }

        var warnings: [Warning] = []
        guard let format = fields["00"] else { throw ParseError.missingMandatoryField("00 Payload Format Indicator") }
        guard let initiationRaw = fields["01"], let initiation = DuitNowQRPayload.Initiation(rawValue: initiationRaw) else {
            throw ParseError.missingMandatoryField("01 Point of Initiation Method")
        }
        guard let mcc = fields["52"], mcc.count == 4, mcc.allSatisfy(\.isNumber) else {
            throw ParseError.missingMandatoryField("52 Merchant Category Code")
        }
        guard let numericCurrency = fields["53"], numericCurrency.count == 3 else {
            throw ParseError.missingMandatoryField("53 Transaction Currency")
        }
        guard let country = fields["58"] else { throw ParseError.missingMandatoryField("58 Country Code") }
        guard let name = fields["59"], !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ParseError.missingMandatoryField("59 Merchant Name")
        }
        let city = fields["60"] ?? ""

        // Merchant account information lives in templates 26–51. Find the DuitNow one if present.
        var aid: String?, acquirer: String?, qrID: String?, descriptor: String?
        var isDuitNow = false
        let accountTemplates = objects.filter { (Int($0.id) ?? 0) >= 26 && (Int($0.id) ?? 0) <= 51 }
        guard !accountTemplates.isEmpty else { throw ParseError.missingMandatoryField("26 Merchant Account Information") }
        for template in accountTemplates {
            guard let sub = try? EMVTLV.parse(template.value, allowDuplicates: true) else { continue }
            let subFields = Dictionary(sub.map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first })
            let templateAID = subFields["00"]
            if templateAID?.uppercased() == Self.duitNowAID || aid == nil {
                aid = templateAID
                acquirer = subFields["01"]
                qrID = subFields["02"]
                descriptor = subFields["03"]
            }
            if templateAID?.uppercased() == Self.duitNowAID { isDuitNow = true; break }
        }
        if !isDuitNow { warnings.append(.notDuitNow) }
        if country.uppercased() != "MY" { warnings.append(.nonMalaysianCountry) }

        let currency = CurrencyCode.fromNumeric(numericCurrency)
        if currency == nil { warnings.append(.unsupportedCurrency) }

        var amount: Money?
        if let amountText = fields["54"] {
            amount = try Self.parseQRAmount(amountText, currency: currency ?? .myr)
            if initiation == .staticQR { warnings.append(.amountOnStaticQR) }
        } else if initiation == .dynamicQR {
            warnings.append(.dynamicWithoutAmount)
        }

        var feeFixed: Money?, feePercent: Decimal?
        let tip = fields["55"]
        if tip == "02", let fixed = fields["56"] { feeFixed = try Self.parseQRAmount(fixed, currency: currency ?? .myr) }
        if tip == "03", let percent = fields["57"] { feePercent = Decimal(string: percent, locale: Locale(identifier: "en_US_POSIX")) }

        var additional: [String: String] = [:]
        if let template = fields["62"], let sub = try? EMVTLV.parse(template, allowDuplicates: true) {
            for object in sub { additional[object.id] = object.value }
        }
        var alternateName: String?
        if let template = fields["64"], let sub = try? EMVTLV.parse(template, allowDuplicates: true) {
            alternateName = sub.first(where: { $0.id == "01" })?.value
        }

        let postal = fields["61"]
        if let postal, !(postal.count == 5 && postal.allSatisfy(\.isNumber)) { warnings.append(.invalidPostalCode) }
        if name.count > 25 { warnings.append(.merchantNameTruncated) }

        let knownTags: Set<String> = ["00", "01", "52", "53", "54", "55", "56", "57", "58", "59", "60", "61", "62", "63", "64", "82"]
        let unrecognised = objects.map(\.id).filter { id in
            guard !knownTags.contains(id) else { return false }
            let number = Int(id) ?? 0
            return !(2...51).contains(number)
        }

        func meaningful(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value != "***" else { return nil }
            return InputSanitizer.cleanText(value, maxLength: 64)
        }

        return DuitNowQRPayload(
            payloadFormat: format,
            initiation: initiation,
            isDuitNow: isDuitNow,
            applicationIdentifier: aid,
            acquirerID: acquirer,
            qrID: qrID,
            merchantDescriptor: meaningful(descriptor),
            merchantCategoryCode: mcc,
            currency: currency,
            numericCurrency: numericCurrency,
            amount: amount,
            tipIndicator: tip,
            convenienceFeeFixed: feeFixed,
            convenienceFeePercentage: feePercent,
            countryCode: country,
            merchantName: InputSanitizer.cleanText(name, maxLength: 64),
            merchantCity: InputSanitizer.cleanText(city, maxLength: 64),
            postalCode: postal,
            billNumber: meaningful(additional["01"]),
            referenceLabel: meaningful(additional["05"]),
            storeLabel: meaningful(additional["03"]),
            terminalLabel: meaningful(additional["07"]),
            purpose: meaningful(additional["08"]),
            referenceNumber: meaningful(additional["90"]),
            alternateMerchantName: meaningful(alternateName),
            unrecognisedTags: unrecognised,
            warnings: warnings
        )
    }

    /// Tag 54: digits with at most one ".", non-zero, ≤ 13 characters.
    static func parseQRAmount(_ text: String, currency: CurrencyCode) throws -> Money {
        guard text.count <= 13, !text.isEmpty,
              text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              text.filter({ $0 == "." }).count <= 1 else { throw ParseError.invalidAmount(text) }
        let parser = AmountParser(currency: currency)
        guard let result = try? parser.parse(text), !result.money.isZero else { throw ParseError.invalidAmount(text) }
        return result.money
    }
}

/// Turns a scanned QR into a draft transaction. The draft never counts toward spending until the
/// payment is confirmed (receipt, statement import or explicit user confirmation).
public enum DuitNowDraftFactory {
    public static func draft(from payload: DuitNowQRPayload, accountID: UUID? = nil, scannedAt: Date = Date(),
                             engine: CategoryEngine = CategoryEngine(), rules: [MerchantRule] = []) -> TransactionRecord {
        let merchant = payload.merchantDescriptor ?? payload.merchantName
        let categorisation = engine.categorise(merchant: merchant, description: payload.merchantName,
                                               merchantCategoryCode: payload.merchantCategoryCode, rules: rules)
        var flags: Set<ReviewFlag> = [.unconfirmedPayment]
        let amount = payload.amount ?? .zero(payload.currency ?? .myr)
        if payload.amount == nil { flags.insert(.amountMissing) }
        if payload.currency != .myr { flags.insert(.foreignCurrency) }
        let kind: TransactionKind = payload.isPersonToPerson ? .transfer : (categorisation.kindHint ?? .expense)
        let reference = payload.referenceNumber ?? payload.billNumber ?? payload.referenceLabel

        return TransactionRecord(
            accountID: accountID,
            amount: amount,
            direction: .outflow,
            kind: kind,
            merchant: MerchantNormalizer.displayName(merchant),
            transactionDescription: [payload.merchantName, payload.merchantCity].filter { !$0.isEmpty }.joined(separator: ", "),
            transactionDate: scannedAt,
            channel: .duitNowQR,
            categoryID: categorisation.categoryID,
            status: .draft,
            source: .duitNowQR,
            externalReference: reference,
            confidence: payload.amount == nil ? 0.4 : 0.7,
            flags: flags,
            merchantCategoryCode: payload.merchantCategoryCode,
            createdAt: scannedAt,
            updatedAt: scannedAt
        )
    }
}
