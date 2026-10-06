import XCTest
@testable import VectorCore

final class OpenFoodFactsTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testParsesSearchResults() throws {
        let items = OpenFoodFactsClient.parseSearch(try fixture("off-search"))
        XCTAssertGreaterThanOrEqual(items.count, 5)
        let first = try XCTUnwrap(items.first)
        XCTAssertEqual(first.name, "Nonfat Greek Yogurt")
        XCTAssertEqual(first.brand, "Chobani")
        XCTAssertEqual(first.id, "off-0894700010137")
        XCTAssertEqual(first.per100g.protein, 9.41, accuracy: 0.01)
        XCTAssertEqual(first.servingGrams, 100, "No serving size given, so default to 100 g")
    }

    func testContradictoryCaloriesFallBackToMacros() throws {
        // "Raspberry Greek Yogurt" claims 193 kcal/100 g but its macros add up to ~129.
        let items = OpenFoodFactsClient.parseSearch(try fixture("off-search"))
        let raspberry = try XCTUnwrap(items.first { $0.name == "Raspberry Greek Yogurt" && $0.per100g.carbs > 15 })
        XCTAssertEqual(raspberry.per100g.calories, raspberry.per100g.caloriesFromMacros, accuracy: 0.1)
    }

    func testParsesBarcodeProduct() throws {
        let item = try XCTUnwrap(OpenFoodFactsClient.parseProduct(try fixture("off-product")))
        XCTAssertEqual(item.name, "Mars")
        XCTAssertEqual(item.barcode, "5000159407236")
        XCTAssertEqual(item.brand, "Mars")
        XCTAssertEqual(item.per100g.calories, 450, accuracy: 1)
    }

    func testRejectsUnusableProducts() {
        XCTAssertNil(OpenFoodFactsClient.parseProductObject(["product_name": "Mystery", "nutriments": [String: Any]()]))
        XCTAssertNil(OpenFoodFactsClient.parseProductObject(["product_name": " ", "nutriments": ["proteins_100g": 10.0]]))
        XCTAssertNil(OpenFoodFactsClient.parseProductObject(["product_name": "Broken", "nutriments": ["proteins_100g": 80.0, "carbohydrates_100g": 80.0]]))
        XCTAssertNil(OpenFoodFactsClient.parseProduct(Data(#"{"status":0}"#.utf8)))
        let kj = OpenFoodFactsClient.parseProductObject(["product_name": "Oats", "code": "1",
                                                         "nutriments": ["energy_100g": 1586.0, "proteins_100g": 13.2, "carbohydrates_100g": 67.7, "fat_100g": 6.5]])
        XCTAssertEqual(kj?.per100g.calories ?? 0, 379, accuracy: 2, "kJ-only products are converted to kcal")
    }

    /// Hits the real API. Run with `VECTOR_LIVE_TESTS=1 swift test`.
    func testLiveSearchAndBarcode() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VECTOR_LIVE_TESTS"] == "1", "Live network test")
        let client = OpenFoodFactsClient()
        let results = try await client.search("chicken breast", limit: 5)
        XCTAssertFalse(results.isEmpty)
        let mars = try await client.product(barcode: "5000159407236")
        XCTAssertEqual(mars?.name, "Mars")
    }
}
