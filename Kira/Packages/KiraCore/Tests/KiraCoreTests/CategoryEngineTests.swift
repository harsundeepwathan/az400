import XCTest
@testable import KiraCore

final class CategoryEngineTests: XCTestCase {
    let engine = CategoryEngine()

    func testMalaysianMerchants() {
        let expectations: [(String, BuiltInCategory)] = [
            ("PETRONAS SS2 PJ", .petrol), ("SHELL-JLN DUTA", .petrol),
            ("GRAB* A-5XYZ123 KUALA LUMPUR MY", .rideHailing), ("GRABFOOD*ORDER 991", .foodDelivery),
            ("LOTUS'S KEPONG", .groceries), ("LOTUSS STORES (M) SDN BHD", .groceries), ("AEON BIG MID VALLEY", .groceries),
            ("JAYA GROCER BANGSAR", .groceries), ("JAYAGROCER", .groceries), ("VILLAGE GROCER", .groceries),
            ("SHOPEE MALAYSIA", .shopping), ("LAZADA", .shopping), ("FOODPANDA MALAYSIA", .foodDelivery),
            ("STARBUCKS PAVILION KL", .coffee), ("ZUS COFFEE - SS15 SUBANG", .coffee),
            ("FAMILYMART KLCC", .groceries), ("7-ELEVEN MALAYSIA", .groceries),
            ("TNB BILL PAYMENT", .utilities), ("NETFLIX.COM", .subscriptions), ("PLUS JALAN DUTA", .tolls),
            ("RESTORAN NASI KANDAR ALI", .restaurants), ("KLINIK DR TAN", .healthcare)
        ]
        for (text, category) in expectations {
            let result = engine.categorise(merchant: nil, description: text)
            XCTAssertEqual(result.categoryID, category.id, "\(text) → \(result.categoryID) via \(result.layer)")
        }
    }

    func testWalletReloadHasTopUpHint() {
        let result = engine.categorise(merchant: nil, description: "TNG EWALLET RELOAD")
        XCTAssertEqual(result.kindHint, .walletTopUp)
    }

    func testUserRuleBeatsDictionary() {
        let rule = MerchantRule(pattern: "Starbucks", matchType: .contains, categoryID: BuiltInCategory.gifts.id)
        XCTAssertEqual(engine.categorise(merchant: "STARBUCKS PAVILION", description: "", rules: [rule]).categoryID, BuiltInCategory.gifts.id)
        XCTAssertEqual(engine.categorise(merchant: "STARBUCKS PAVILION", description: "", rules: [rule]).layer, .userRule)
    }

    func testMCCFallback() {
        let result = engine.categorise(merchant: "KEDAI XYZ ENTERPRISE", description: "", merchantCategoryCode: "5411")
        XCTAssertEqual(result.categoryID, BuiltInCategory.groceries.id)
        XCTAssertEqual(result.layer, .merchantCategoryCode)
        XCTAssertEqual(engine.categorise(merchant: "AHMAD", description: "", merchantCategoryCode: "0000").kindHint, .transfer)
    }

    func testUnknownFallsBackWithLowConfidence() {
        let result = engine.categorise(merchant: "QWERTY ZXCV", description: "")
        XCTAssertEqual(result.categoryID, BuiltInCategory.other.id)
        XCTAssertLessThan(result.confidence, engine.reviewThreshold)
    }

    func testApplyNeverOverridesUserChoice() {
        var record = TestData.tx("10.00", category: BuiltInCategory.gifts.id, merchant: "Starbucks")
        record.categoryIsUserSet = true
        XCTAssertEqual(engine.apply(to: record, rules: []).categoryID, BuiltInCategory.gifts.id)
        record.categoryIsUserSet = false
        XCTAssertEqual(engine.apply(to: record, rules: []).categoryID, BuiltInCategory.coffee.id)
    }

    func testLearningFromCorrectionAppliesToFutureOnly() throws {
        let corrected = TestData.tx("25.00", category: BuiltInCategory.other.id, merchant: "KEDAI MAKAN MAK LIMAH")
        let rule = try XCTUnwrap(CategoryEngine.learnRule(from: corrected, newCategoryID: BuiltInCategory.restaurants.id))
        XCTAssertTrue(rule.learnedFromCorrection)
        let future = TestData.tx("12.00", category: nil, merchant: "Kedai Makan Mak Limah")
        XCTAssertEqual(engine.apply(to: future, rules: [rule]).categoryID, BuiltInCategory.restaurants.id)
        // A user-set existing record keeps its explicit category even when a new rule matches.
        var explicit = TestData.tx("30.00", category: BuiltInCategory.gifts.id, merchant: "Kedai Makan Mak Limah")
        explicit.categoryIsUserSet = true
        XCTAssertEqual(engine.apply(to: explicit, rules: [rule]).categoryID, BuiltInCategory.gifts.id)
    }

    func testMerchantNormalizer() {
        XCTAssertEqual(MerchantNormalizer.key("GRAB* A-5XYZ123 KUALA LUMPUR MY"), "GRAB")
        XCTAssertEqual(MerchantNormalizer.key("LOTUSS STORES (M) SDN BHD"), "LOTUSS STORES")
        XCTAssertEqual(MerchantNormalizer.key("POS PURCHASE 123456789 PETRONAS"), "PETRONAS")
        XCTAssertEqual(MerchantNormalizer.displayName("ZUS COFFEE"), "Zus Coffee")
    }

    func testSimilarity() {
        XCTAssertEqual(TextSimilarity.merchant("ZUS Coffee", "ZUS COFFEE SS15"), 0.85, accuracy: 0.001)
        XCTAssertGreaterThan(TextSimilarity.merchant("Starbucks Pavilion", "STARBUCKS PAVILION KL"), 0.8)
        XCTAssertLessThan(TextSimilarity.merchant("Petronas", "Jaya Grocer"), 0.4)
        XCTAssertEqual(TextSimilarity.levenshtein("kitten", "sitting"), 3)
    }
}
