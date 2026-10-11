import Foundation

/// A known Malaysian merchant and the aliases it appears under on statements and receipts.
public struct MerchantEntry: Hashable, Sendable {
    public let canonicalName: String
    /// Normalised (MerchantNormalizer.key) alias phrases matched on word boundaries.
    public let aliases: [String]
    public let category: BuiltInCategory
    public let confidence: Double
    public let kindHint: TransactionKind?

    public init(_ canonicalName: String, _ aliases: [String], _ category: BuiltInCategory, confidence: Double = 0.9, kindHint: TransactionKind? = nil) {
        self.canonicalName = canonicalName
        self.aliases = aliases.map { MerchantNormalizer.key($0) }.filter { !$0.isEmpty }
        self.category = category
        self.confidence = confidence
        self.kindHint = kindHint
    }
}

/// Bundled, on-device merchant dictionary (layer 2). Order of entries does not matter:
/// the longest matching alias wins so "GRAB FOOD" beats "GRAB".
public struct MerchantDictionary: Sendable {
    public let entries: [MerchantEntry]
    private let index: [(alias: String, entry: MerchantEntry)]

    public init(entries: [MerchantEntry] = MerchantDictionary.malaysia) {
        self.entries = entries
        self.index = entries.flatMap { entry in entry.aliases.map { ($0, entry) } }
            .sorted { $0.alias.count > $1.alias.count }
    }

    public func lookup(_ raw: String) -> (entry: MerchantEntry, alias: String)? {
        let key = " " + MerchantNormalizer.key(raw) + " "
        let compact = key.replacingOccurrences(of: " ", with: "")
        for (alias, entry) in index {
            if key.contains(" " + alias + " ") { return (entry, alias) }
            // Statements often squash words: "JAYAGROCER", "ZUSCOFFEE".
            let squashed = alias.replacingOccurrences(of: " ", with: "")
            if squashed.count >= 5 && compact.contains(squashed) { return (entry, alias) }
        }
        return nil
    }

    public static let malaysia: [MerchantEntry] = [
        // Petrol
        MerchantEntry("Petronas", ["PETRONAS", "PETRONAS MESRA", "SETEL"], .petrol),
        MerchantEntry("Shell", ["SHELL", "SHELL SELECT", "SHELL MALAYSIA"], .petrol),
        MerchantEntry("Caltex", ["CALTEX"], .petrol),
        MerchantEntry("BHPetrol", ["BHPETROL", "BHP"], .petrol, confidence: 0.8),
        MerchantEntry("Petron", ["PETRON"], .petrol),
        // Ride hailing / Grab family
        MerchantEntry("GrabFood", ["GRABFOOD", "GRAB FOOD"], .foodDelivery),
        MerchantEntry("GrabMart", ["GRABMART", "GRAB MART"], .groceries, confidence: 0.85),
        MerchantEntry("GrabPay top-up", ["GRABPAY TOP UP", "GRABPAY TOPUP", "GRAB TOP UP"], .transfers, kindHint: .walletTopUp),
        MerchantEntry("Grab", ["GRAB", "GRABCAR", "GRAB CAR", "GRAB RIDES", "GRABTAXI", "GRAB TRANSPORT"], .rideHailing, confidence: 0.75),
        MerchantEntry("AirAsia Ride", ["AIRASIA RIDE"], .rideHailing),
        MerchantEntry("inDrive", ["INDRIVE", "INDRIVER"], .rideHailing),
        MerchantEntry("Maxim", ["MAXIM TAXI"], .rideHailing),
        // Touch 'n Go: reloads are top-ups; RFID/toll usage is tolls.
        MerchantEntry("Touch ’n Go reload", ["TNG RELOAD", "TNG EWALLET RELOAD", "TOUCH N GO RELOAD", "TNG DIGITAL RELOAD"], .transfers, kindHint: .walletTopUp),
        MerchantEntry("Touch ’n Go", ["TOUCH N GO", "TOUCH NGO", "TNG", "TNGD", "TNG DIGITAL"], .tolls, confidence: 0.6),
        MerchantEntry("PLUS Highway", ["PLUS", "PLUS MALAYSIA", "PLUSMILES", "LEBUHRAYA"], .tolls, confidence: 0.7),
        MerchantEntry("SmartTAG / RFID", ["SMARTTAG", "RFID"], .tolls),
        // Groceries & convenience
        MerchantEntry("Lotus’s", ["LOTUSS", "LOTUS S", "LOTUS'S", "LOTUS STORES", "TESCO"], .groceries),
        MerchantEntry("AEON", ["AEON", "AEON BIG", "AEON CO", "AEON MAXVALU"], .groceries, confidence: 0.75),
        MerchantEntry("Jaya Grocer", ["JAYA GROCER"], .groceries),
        MerchantEntry("Village Grocer", ["VILLAGE GROCER"], .groceries),
        MerchantEntry("Mydin", ["MYDIN"], .groceries),
        MerchantEntry("Giant", ["GIANT", "GIANT HYPERMARKET"], .groceries, confidence: 0.8),
        MerchantEntry("Econsave", ["ECONSAVE"], .groceries),
        MerchantEntry("NSK", ["NSK TRADE CITY", "NSK GROCER"], .groceries),
        MerchantEntry("99 Speedmart", ["99 SPEEDMART", "SPEEDMART"], .groceries),
        MerchantEntry("KK Mart", ["KK MART", "KK SUPER MART", "KKSM"], .groceries, confidence: 0.85),
        MerchantEntry("FamilyMart", ["FAMILYMART", "FAMILY MART"], .groceries, confidence: 0.8),
        MerchantEntry("7-Eleven", ["7 ELEVEN", "7ELEVEN", "SEVEN ELEVEN", "7 11"], .groceries, confidence: 0.8),
        MerchantEntry("Ben’s Independent Grocer", ["BIG GROCER", "BENS INDEPENDENT GROCER"], .groceries),
        // Coffee & cafés
        MerchantEntry("Starbucks", ["STARBUCKS", "BERJAYA STARBUCKS"], .coffee),
        MerchantEntry("ZUS Coffee", ["ZUS COFFEE", "ZUS"], .coffee),
        MerchantEntry("Tealive", ["TEALIVE"], .coffee),
        MerchantEntry("Gigi Coffee", ["GIGI COFFEE"], .coffee),
        MerchantEntry("Bask Bear", ["BASK BEAR"], .coffee),
        MerchantEntry("Luckin Coffee", ["LUCKIN"], .coffee),
        MerchantEntry("The Coffee Bean", ["COFFEE BEAN", "COFFEE BEAN & TEA LEAF"], .coffee),
        MerchantEntry("OldTown White Coffee", ["OLDTOWN", "OLD TOWN WHITE COFFEE"], .coffee),
        MerchantEntry("Kenangan Coffee", ["KOPI KENANGAN", "KENANGAN COFFEE"], .coffee),
        // Restaurants & fast food
        MerchantEntry("McDonald’s", ["MCDONALDS", "MCDONALD S", "MCD"], .restaurants),
        MerchantEntry("KFC", ["KFC"], .restaurants),
        MerchantEntry("Marrybrown", ["MARRYBROWN"], .restaurants),
        MerchantEntry("Nando’s", ["NANDOS", "NANDO S"], .restaurants),
        MerchantEntry("Secret Recipe", ["SECRET RECIPE"], .restaurants),
        MerchantEntry("Sushi King", ["SUSHI KING"], .restaurants),
        MerchantEntry("Pizza Hut", ["PIZZA HUT"], .restaurants),
        MerchantEntry("Domino’s", ["DOMINOS", "DOMINO S"], .restaurants),
        MerchantEntry("Texas Chicken", ["TEXAS CHICKEN"], .restaurants),
        MerchantEntry("Subway", ["SUBWAY"], .restaurants, confidence: 0.8),
        // Food delivery
        MerchantEntry("foodpanda", ["FOODPANDA", "FOOD PANDA"], .foodDelivery),
        MerchantEntry("ShopeeFood", ["SHOPEEFOOD", "SHOPEE FOOD"], .foodDelivery),
        // Shopping
        MerchantEntry("ShopeePay top-up", ["SHOPEEPAY TOP UP", "SHOPEEPAY TOPUP"], .transfers, kindHint: .walletTopUp),
        MerchantEntry("Shopee", ["SHOPEE", "SHOPEE MALAYSIA", "SHOPEEPAY"], .shopping, confidence: 0.8),
        MerchantEntry("Lazada", ["LAZADA"], .shopping),
        MerchantEntry("TikTok Shop", ["TIKTOK SHOP"], .shopping),
        MerchantEntry("Zalora", ["ZALORA"], .shopping),
        MerchantEntry("Uniqlo", ["UNIQLO"], .shopping),
        MerchantEntry("IKEA", ["IKEA"], .shopping),
        MerchantEntry("MR DIY", ["MR DIY", "MRDIY"], .shopping),
        MerchantEntry("Daiso", ["DAISO"], .shopping),
        MerchantEntry("Apple Store", ["APPLE STORE"], .shopping),
        // Utilities & telco
        MerchantEntry("TNB", ["TNB", "TENAGA NASIONAL", "MYTNB"], .utilities),
        MerchantEntry("Air Selangor", ["AIR SELANGOR", "PENGURUSAN AIR SELANGOR"], .utilities),
        MerchantEntry("Indah Water", ["INDAH WATER", "IWK"], .utilities),
        MerchantEntry("SAJ", ["RANHILL SAJ", "SAJ"], .utilities, confidence: 0.7),
        MerchantEntry("Maxis", ["MAXIS", "HOTLINK"], .mobileInternet),
        MerchantEntry("CelcomDigi", ["CELCOMDIGI", "CELCOM", "DIGI"], .mobileInternet),
        MerchantEntry("U Mobile", ["U MOBILE", "UMOBILE"], .mobileInternet),
        MerchantEntry("Unifi", ["UNIFI", "TM UNIFI", "TELEKOM MALAYSIA"], .mobileInternet),
        MerchantEntry("TIME", ["TIME DOTCOM", "TIME FIBRE"], .mobileInternet),
        MerchantEntry("Yoodo", ["YOODO"], .mobileInternet),
        MerchantEntry("Tune Talk", ["TUNE TALK"], .mobileInternet),
        // Subscriptions & digital
        MerchantEntry("Netflix", ["NETFLIX"], .subscriptions),
        MerchantEntry("Spotify", ["SPOTIFY"], .subscriptions),
        MerchantEntry("Apple Services", ["APPLE COM BILL", "APPLE COM", "ITUNES", "ICLOUD"], .subscriptions),
        MerchantEntry("YouTube Premium", ["YOUTUBE PREMIUM", "GOOGLE YOUTUBE"], .subscriptions),
        MerchantEntry("Disney+ Hotstar", ["DISNEY", "HOTSTAR"], .subscriptions),
        MerchantEntry("Astro", ["ASTRO", "SOOKA"], .subscriptions, confidence: 0.8),
        MerchantEntry("Viu", ["VIU"], .subscriptions, confidence: 0.75),
        // Public transport
        MerchantEntry("Rapid KL", ["RAPID KL", "RAPIDKL", "PRASARANA", "MYRAPID", "MRT", "LRT"], .publicTransport),
        MerchantEntry("KTM", ["KTM", "KTMB", "KERETAPI TANAH MELAYU"], .publicTransport),
        // Parking
        MerchantEntry("Parking", ["FLEXIPARKING", "JOMPARKING", "SMART SELANGOR PARKING", "PARKING", "PARKIR"], .parking, confidence: 0.85),
        // Travel
        MerchantEntry("AirAsia", ["AIRASIA", "AIR ASIA", "AIRASIA MOVE"], .travel),
        MerchantEntry("Malaysia Airlines", ["MALAYSIA AIRLINES", "MALAYSIAN AIRLINE"], .travel),
        MerchantEntry("Firefly", ["FIREFLY"], .travel, confidence: 0.8),
        MerchantEntry("Batik Air", ["BATIK AIR"], .travel),
        MerchantEntry("Agoda", ["AGODA"], .travel),
        MerchantEntry("Booking.com", ["BOOKING COM"], .travel),
        // Entertainment
        MerchantEntry("GSC", ["GSC", "GOLDEN SCREEN"], .entertainment),
        MerchantEntry("TGV Cinemas", ["TGV"], .entertainment),
        MerchantEntry("MBO Cinemas", ["MBO CINEMAS"], .entertainment),
        MerchantEntry("Steam", ["STEAM", "STEAMPOWERED"], .entertainment, confidence: 0.75),
        // Health, fitness, personal care
        MerchantEntry("Watsons", ["WATSONS"], .personalCare),
        MerchantEntry("Guardian", ["GUARDIAN"], .personalCare, confidence: 0.8),
        MerchantEntry("Caring Pharmacy", ["CARING PHARMACY", "CARING"], .healthcare),
        MerchantEntry("Alpro Pharmacy", ["ALPRO"], .healthcare),
        MerchantEntry("KPJ", ["KPJ"], .healthcare),
        MerchantEntry("Anytime Fitness", ["ANYTIME FITNESS"], .fitness),
        MerchantEntry("Celebrity Fitness", ["CELEBRITY FITNESS"], .fitness),
        MerchantEntry("Fitness First", ["FITNESS FIRST"], .fitness),
        // Insurance
        MerchantEntry("Great Eastern", ["GREAT EASTERN"], .insurance),
        MerchantEntry("Prudential", ["PRUDENTIAL", "PRUBSN"], .insurance),
        MerchantEntry("AIA", ["AIA"], .insurance, confidence: 0.8),
        MerchantEntry("Allianz", ["ALLIANZ"], .insurance),
        MerchantEntry("Etiqa", ["ETIQA"], .insurance),
        MerchantEntry("Takaful", ["TAKAFUL"], .insurance, confidence: 0.85),
        // Debt
        MerchantEntry("PTPTN", ["PTPTN"], .transfers, kindHint: .debtRepayment)
    ]
}
