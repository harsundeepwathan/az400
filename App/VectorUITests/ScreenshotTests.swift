import XCTest

/// Captures the main screens for review. The CI "Screenshots" workflow runs
/// this in light and dark mode and publishes the PNGs to the `screenshots`
/// branch. Set SHOT_DIR (via TEST_RUNNER_SHOT_DIR) to also write files.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
    }

    func testWelcome() {
        launch(sampleData: false)
        _ = app.buttons["Continue"].waitForExistence(timeout: 10)
        shoot("01-welcome")
    }

    func testMainScreens() {
        launch(sampleData: true)
        _ = tabButton("Today").waitForExistence(timeout: 10)
        sleep(1)
        shoot("02-today")
        // Tabs first: on iOS 26 the tab bar shrinks once the list scrolls.
        for (index, tab) in ["Train", "Nutrition", "Progress"].enumerated() {
            let button = tabButton(tab)
            if button.waitForExistence(timeout: 5) { button.tap() }
            sleep(1)
            shoot(String(format: "%02d-%@", index + 4, tab.lowercased()))
        }
        // Coach (from Progress), with Ask your data.
        let coach = app.buttons["Coach"].firstMatch
        if coach.waitForExistence(timeout: 3) {
            coach.tap()
            sleep(2)
            app.swipeUp()
            sleep(1)
            shoot("08-coach")
            let done = app.buttons["Done"].firstMatch
            if done.waitForExistence(timeout: 3) { done.tap() }
            sleep(1)
        }
        tabButton("Today").tap()
        sleep(1)
        app.swipeUp()
        sleep(1)
        shoot("03-today-scrolled")
        app.swipeUp()
        sleep(1)
        shoot("03b-today-muscles")
        app.swipeDown()
        app.swipeDown()
        sleep(1)
        // The workout screen with one set done (green row) and the live stats strip.
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Start workout")).firstMatch
        if start.waitForExistence(timeout: 5) {
            start.tap()
            let complete = app.buttons["Complete set"].firstMatch
            if complete.waitForExistence(timeout: 5) { complete.tap() }
            sleep(4) // let the record toast clear
            shoot("07-workout")
        }
    }

    private func tabButton(_ title: String) -> XCUIElement {
        app.tabBars.buttons[title].exists ? app.tabBars.buttons[title] : app.buttons[title]
    }

    private func launch(sampleData: Bool) {
        app = XCUIApplication()
        app.launchArguments = ["-uiTesting"] + (sampleData ? ["-sampleData"] : [])
        app.launch()
    }

    private func shoot(_ name: String) {
        let env = ProcessInfo.processInfo.environment
        let suffix = env["SHOT_SUFFIX"].map { "-\($0)" } ?? ""
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name + suffix
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["SHOT_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)\(suffix).png")
            try? shot.pngRepresentation.write(to: url)
        }
    }
}
