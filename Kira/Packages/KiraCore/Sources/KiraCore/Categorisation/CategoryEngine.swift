import Foundation

/// Optional, consent-gated fallback (layer 5). Kira ships no implementation that sends data
/// off-device; an implementation must only be wired in after explicit user opt-in.
public protocol CategorySuggestionProvider: Sendable {
    func suggestCategory(merchant: String?, description: String, availableCategoryIDs: [String]) async throws -> (categoryID: String, confidence: Double)?
}

public struct CategorisationResult: Equatable, Sendable {
    public enum Layer: String, Sendable, Equatable {
        case userRule, merchantDictionary, descriptionKeywords, merchantCategoryCode, aiFallback, fallback
    }

    public let categoryID: String
    public let confidence: Double
    public let layer: Layer
    public let kindHint: TransactionKind?
    /// Clean merchant name when the dictionary recognised it.
    public let canonicalMerchant: String?
}

/// Layered categorisation:
/// 1. User rules → 2. Merchant dictionary → 3. Description keywords → 4. MCC → (5. optional AI) → Other.
public struct CategoryEngine: Sendable {
    public var dictionary: MerchantDictionary
    /// Results below this confidence get the `.lowConfidenceCategory` review flag.
    public var reviewThreshold: Double

    public init(dictionary: MerchantDictionary = MerchantDictionary(), reviewThreshold: Double = 0.6) {
        self.dictionary = dictionary
        self.reviewThreshold = reviewThreshold
    }

    public func categorise(merchant: String?, description: String, merchantCategoryCode: String? = nil, rules: [MerchantRule] = []) -> CategorisationResult {
        let texts = [merchant, description].compactMap { $0 }.filter { !$0.isEmpty }

        // 1. User rules — most recent rule wins when several match.
        for rule in rules.sorted(by: { $0.createdAt > $1.createdAt }) where texts.contains(where: { Self.matches(rule, $0) }) {
            return CategorisationResult(categoryID: rule.categoryID, confidence: 1.0, layer: .userRule, kindHint: rule.kind, canonicalMerchant: nil)
        }

        // 2. Merchant dictionary.
        for text in texts {
            if let hit = dictionary.lookup(text) {
                return CategorisationResult(categoryID: hit.entry.category.id, confidence: hit.entry.confidence, layer: .merchantDictionary,
                                            kindHint: hit.entry.kindHint, canonicalMerchant: hit.entry.canonicalName)
            }
        }

        // 3. Generic description keywords.
        let haystack = " " + texts.map { MerchantNormalizer.key($0) }.joined(separator: " ") + " "
        for (keywords, category) in Self.keywordRules where keywords.contains(where: { haystack.contains(" \($0) ") }) {
            return CategorisationResult(categoryID: category.id, confidence: 0.65, layer: .descriptionKeywords, kindHint: nil, canonicalMerchant: nil)
        }

        // 4. Merchant category code.
        if let mcc = merchantCategoryCode, let mapped = Self.categoryForMCC(mcc) {
            return CategorisationResult(categoryID: mapped.category.id, confidence: 0.6, layer: .merchantCategoryCode, kindHint: mapped.kind, canonicalMerchant: nil)
        }

        return CategorisationResult(categoryID: BuiltInCategory.other.id, confidence: 0.2, layer: .fallback, kindHint: nil, canonicalMerchant: nil)
    }

    /// Applies categorisation to a record without touching a user-set category.
    public func apply(to record: TransactionRecord, rules: [MerchantRule]) -> TransactionRecord {
        guard !record.categoryIsUserSet else { return record }
        var updated = record
        let result = categorise(merchant: record.merchant, description: record.transactionDescription,
                                merchantCategoryCode: record.merchantCategoryCode, rules: rules)
        updated.categoryID = result.categoryID
        if result.confidence < reviewThreshold {
            updated.flags.insert(.lowConfidenceCategory)
        } else {
            updated.flags.remove(.lowConfidenceCategory)
        }
        return updated
    }

    /// Turns a user's correction into a rule for future transactions. Existing records are not
    /// modified here; callers re-run `apply` only on records whose category is not user-set.
    public static func learnRule(from record: TransactionRecord, newCategoryID: String, now: Date = Date()) -> MerchantRule? {
        let source = record.merchant.flatMap { $0.isEmpty ? nil : $0 } ?? record.transactionDescription
        let key = MerchantNormalizer.key(source)
        guard key.count >= 3 else { return nil }
        return MerchantRule(pattern: key, matchType: .exact, categoryID: newCategoryID, learnedFromCorrection: true, createdAt: now)
    }

    static func matches(_ rule: MerchantRule, _ text: String) -> Bool {
        let pattern = MerchantNormalizer.key(rule.pattern)
        let key = MerchantNormalizer.key(text)
        guard !pattern.isEmpty else { return false }
        switch rule.matchType {
        case .exact: return key == pattern
        case .prefix: return key.hasPrefix(pattern)
        case .contains: return (" " + key + " ").contains(" " + pattern + " ") || key.contains(pattern) && pattern.count >= 5
        }
    }

    static let keywordRules: [([String], BuiltInCategory)] = [
        (["MAMAK", "NASI KANDAR", "RESTORAN", "RESTAURANT", "KEDAI MAKAN", "KOPITIAM", "WARUNG", "BISTRO", "CAFE", "CAFETERIA", "STALL", "MEDAN SELERA", "FOOD COURT"], .restaurants),
        (["COFFEE", "KOPI", "ESPRESSO", "ROASTERS"], .coffee),
        (["SUPERMARKET", "HYPERMARKET", "MINIMARKET", "MINI MARKET", "PASAR", "GROCER", "GROCERY", "MART", "KEDAI RUNCIT"], .groceries),
        (["PETROL", "STESEN MINYAK", "FUEL", "MINYAK"], .petrol),
        (["TOL", "TOLL", "PLAZA TOL"], .tolls),
        (["PARKING", "PARKIR", "LETAK KERETA"], .parking),
        (["KLINIK", "CLINIC", "HOSPITAL", "FARMASI", "PHARMACY", "DENTAL", "PERGIGIAN", "MEDICAL", "PERUBATAN"], .healthcare),
        (["GYM", "FITNESS", "YOGA", "PILATES", "BADMINTON", "FUTSAL"], .fitness),
        (["CINEMA", "PANGGUNG", "KARAOKE", "BOWLING", "CONCERT"], .entertainment),
        (["HOTEL", "RESORT", "AIRLINE", "AIRLINES", "AIRPORT", "HOMESTAY"], .travel),
        (["UNIVERSITI", "UNIVERSITY", "COLLEGE", "KOLEJ", "SCHOOL", "SEKOLAH", "TUITION", "TUISYEN", "TADIKA"], .education),
        (["SALON", "BARBER", "GUNTING", "SPA", "BEAUTY", "NAIL"], .personalCare),
        (["FLORIST", "BUNGA", "GIFT", "HADIAH"], .gifts),
        (["INSURANCE", "INSURANS", "TAKAFUL"], .insurance),
        (["MAINTENANCE FEE", "SINKING FUND", "MANAGEMENT CORP", "JMB", "RENTAL", "SEWA RUMAH"], .housing),
        (["ELEKTRIK", "ELECTRICITY", "WATER BILL", "BIL AIR", "CUKAI TAKSIRAN", "QUIT RENT", "CUKAI TANAH"], .utilities),
        (["PREPAID", "POSTPAID", "BROADBAND", "FIBRE", "TOPUP MOBILE", "RELOAD MOBILE"], .mobileInternet),
        (["SUBSCRIPTION", "LANGGANAN", "MEMBERSHIP"], .subscriptions)
    ]

    /// ISO 18245 merchant category code → category (and kind hint for P2P transfers).
    public static func categoryForMCC(_ code: String) -> (category: BuiltInCategory, kind: TransactionKind?)? {
        guard let value = Int(code) else { return nil }
        switch value {
        case 0: return (.transfers, .transfer) // DuitNow P2P QR uses MCC 0000
        case 5411, 5422, 5441, 5451, 5499: return (.groceries, nil)
        case 5462: return (.coffee, nil)
        case 5812, 5814: return (.restaurants, nil)
        case 5813: return (.entertainment, nil)
        case 5541, 5542, 5983: return (.petrol, nil)
        case 4784: return (.tolls, nil)
        case 7523: return (.parking, nil)
        case 4011, 4111, 4112, 4131: return (.publicTransport, nil)
        case 4121: return (.rideHailing, nil)
        case 4900: return (.utilities, nil)
        case 4812, 4814, 4816: return (.mobileInternet, nil)
        case 4899, 5815, 5816, 5817, 5818: return (.subscriptions, nil)
        case 5310, 5311, 5331, 5399, 5611, 5621, 5651, 5661, 5691, 5699, 5732, 5734, 5945, 5999, 5200, 5251, 5712, 5719: return (.shopping, nil)
        case 5912, 8011, 8021, 8031, 8042, 8043, 8049, 8050, 8062, 8071, 8099: return (.healthcare, nil)
        case 7941, 7997: return (.fitness, nil)
        case 7832, 7922, 7929, 7991, 7996, 7999: return (.entertainment, nil)
        case 3000...3299, 4511, 4411, 4722, 7011, 3501...3999: return (.travel, nil)
        case 8211, 8220, 8241, 8244, 8249, 8299: return (.education, nil)
        case 7230, 7297, 7298: return (.personalCare, nil)
        case 5992, 5947: return (.gifts, nil)
        case 6300, 5960: return (.insurance, nil)
        case 6513: return (.housing, nil)
        case 6010, 6011: return (.transfers, .transfer) // cash withdrawal
        default: return nil
        }
    }
}
