import XCTest
@testable import VectorCore

final class ScanCorrectionTests: XCTestCase {
    let rice = FoodItem(id: "rice", name: "Rice", per100g: Macros(calories: 130, protein: 2.7, carbs: 28, fat: 0.3), servingName: "1 cup", servingGrams: 160)
    let chicken = FoodItem(id: "chicken", name: "Chicken", per100g: Macros(calories: 165, protein: 31, carbs: 0, fat: 3.6), servingName: "1 breast", servingGrams: 150)
    let salmon = FoodItem(id: "salmon", name: "Salmon", per100g: Macros(calories: 208, protein: 20, carbs: 0, fat: 13), servingName: "1 fillet", servingGrams: 150)

    func testEditedMacrosScaleWithPortion() {
        var item = RecognizedFood(food: rice, grams: 200, confidence: 0.9)
        XCTAssertEqual(item.macros.calories, 260, accuracy: 0.01)
        item.setMacros(Macros(calories: 300, protein: 6, carbs: 60, fat: 2))
        XCTAssertTrue(item.hasEditedMacros)
        item.grams = 100
        XCTAssertEqual(item.macros.calories, 150, accuracy: 0.01, "Typed-in values scale with the portion")

        item.setMacros(rice.macros(grams: 100))
        XCTAssertFalse(item.hasEditedMacros, "Setting the computed values back clears the override")

        item.setMacros(Macros(calories: 999, protein: 1, carbs: 1, fat: 1))
        item.replaceFood(chicken)
        XCTAssertFalse(item.hasEditedMacros, "A different food drops the old numbers")
    }

    func testCorrectionSummary() {
        let a = RecognizedFood(food: rice, grams: 200, confidence: 0.9)
        let b = RecognizedFood(food: chicken, grams: 150, confidence: 0.5)
        let c = RecognizedFood(food: salmon, grams: 100, confidence: 0.9)
        var final = [a, b]
        final[0].grams = 150                 // portion changed (25%)
        final[1].replaceFood(salmon)          // renamed
        final[1].grams = 155                  // within 10%: accepted
        final.append(RecognizedFood(food: chicken, grams: 100, confidence: 1)) // added
        final[1].setMacros(Macros(calories: 350, protein: 30, carbs: 0, fat: 20)) // edited from the label

        let summary = ScanCorrection.compare(original: [a, b, c], final: final)
        XCTAssertEqual(summary.itemsDetected, 3)
        XCTAssertEqual(summary.itemsLogged, 3)
        XCTAssertEqual(summary.renamed, 1)
        XCTAssertEqual(summary.removed, 1)
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.portionsChanged, 1)
        XCTAssertEqual(summary.macrosEdited, 1)
        XCTAssertTrue(summary.wasCorrected)

        let untouched = ScanCorrection.compare(original: [a, b], final: [a, b])
        XCTAssertFalse(untouched.wasCorrected)
        XCTAssertEqual(untouched.calorieError, 0)
    }
}
