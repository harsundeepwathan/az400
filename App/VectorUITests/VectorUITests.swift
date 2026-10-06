import XCTest

/// End-to-end flows on the simulator. `-uiTesting` swaps in an in-memory
/// store, the offline meal recognizer and no network catalogue, so runs are
/// deterministic; `-sampleData` preloads eight weeks of history.
final class VectorUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(sampleData: Bool) {
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting"] + (sampleData ? ["-sampleData"] : [])
        app.launch()
    }

    /// Buttons often combine a title with detail text, so match on the start of the label.
    private func button(_ prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing \(element)", file: file, line: line)
        element.tap()
    }

    private func waitForText(_ text: String, timeout: TimeInterval = 5) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            .waitForExistence(timeout: timeout)
    }

    func testOnboardingBuildsAPlan() {
        launch(sampleData: false)
        tap(button("Get Started"))
        let name = app.textFields["First name"]
        tap(name)
        name.typeText("Sam")
        tap(button("Continue"))
        tap(button("Build muscle"))
        tap(button("Intermediate"))
        tap(button("4 days"))
        tap(button("Continue"))
        tap(button("Full gym"))
        tap(button("No preferences"))
        tap(button("Build My Plan"))
        XCTAssertTrue(waitForText("YOUR PLAN IS READY"))
        tap(button("Start My Plan"))
        XCTAssertTrue(waitForText("Lower A"))
    }

    func testLoggingASetStartsTheRestTimer() {
        launch(sampleData: true)
        tap(button("Start Workout"))
        tap(app.buttons["Complete set"].firstMatch)
        XCTAssertTrue(waitForText("Skip rest", timeout: 3))
        tap(button("Skip"))
        tap(button("Finish"))
        tap(button("Finish Workout"))
        XCTAssertTrue(waitForText("Workout complete"))
    }

    func testMealScanReviewAddsMeal() {
        launch(sampleData: true)
        tap(app.tabBars.buttons["Nutrition"])
        tap(button("Scan Meal"))
        tap(button("Try a sample meal"))
        XCTAssertTrue(waitForText("AI estimate", timeout: 8))
        tap(button("Remove Mixed vegetables"))
        tap(button("Add Meal"))
        XCTAssertTrue(waitForText("Added to"))
    }

    func testProgramBrowserSwitchesProgram() {
        launch(sampleData: true)
        tap(app.tabBars.buttons["Train"])
        tap(button("Browse Programs"))
        tap(button("6 days"))
        tap(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Push / Pull / Legs'")).firstMatch)
        tap(button("Switch to this program"))
        tap(button("Switch Program"))
        XCTAssertTrue(waitForText("Push A", timeout: 6))
    }
}
