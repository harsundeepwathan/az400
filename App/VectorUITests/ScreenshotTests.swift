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
        let today = app.buttons["Today"]
        _ = today.waitForExistence(timeout: 10)
        sleep(1)
        shoot("02-today")
        app.swipeUp()
        sleep(1)
        shoot("03-today-scrolled")
        for (index, tab) in ["Train", "Nutrition", "Progress"].enumerated() {
            let button = app.tabBars.buttons[tab].exists ? app.tabBars.buttons[tab] : app.buttons[tab]
            if button.waitForExistence(timeout: 5) { button.tap() }
            sleep(1)
            shoot(String(format: "%02d-%@", index + 4, tab.lowercased()))
        }
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
