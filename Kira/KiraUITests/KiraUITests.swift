import XCTest

/// Smoke tests against an isolated in-memory store (launch argument `-uiTesting`).
final class KiraUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testEmptyStateAndManualEntry() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Start with one transaction"].waitForExistence(timeout: 5))
        app.buttons["Add transaction"].tap()
        XCTAssertTrue(app.buttons["Add manually"].waitForExistence(timeout: 3))
        app.buttons["Add manually"].tap()
        XCTAssertTrue(app.navigationBars["New transaction"].waitForExistence(timeout: 3))
        let amount = app.textFields["Amount in ringgit"]
        amount.tap()
        amount.typeText("12.90")
        let merchant = app.textFields["Merchant or payee"]
        merchant.tap()
        merchant.typeText("ZUS Coffee")
        app.navigationBars.buttons["Save"].tap()

        XCTAssertTrue(app.staticTexts["ZUS Coffee"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testTabsReachableWithLargestDynamicType() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        for tab in ["Activity", "Insights", "Accounts", "Home"] {
            app.tabBars.buttons[tab].tap()
        }
        XCTAssertTrue(app.tabBars.buttons["Home"].isSelected)
    }

    @MainActor
    func testDarkModeLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleInterfaceStyle", "Dark"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
    }
}
