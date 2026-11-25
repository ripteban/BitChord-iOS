import XCTest

/// Real touches on the app, as a finger would (run on the simulator by .github/workflows/ios.yml):
/// the native mini player opens the full player by a tap and by a swipe up,
/// and the native tab bar moves between pages.
final class PlayerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMiniPlayerAndTabBar() throws {
        let app = XCUIApplication()
        // -autotest starts a Debug-page track by itself after a few seconds.
        app.launchArguments = ["-route", "/debug", "-autotest"]
        app.launch()

        let mini = app.buttons["miniPlayer"]
        XCTAssertTrue(mini.waitForExistence(timeout: 60), "the native mini player never appeared")
        sleep(1)
        shot(app, "1-mini-player")

        // 1. Tap.
        mini.tap()
        let close = app.webViews.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "tapping the mini player didn't open the full player")
        XCTAssertFalse(app.webViews.staticTexts["The player couldn’t open"].exists, "the full player failed to render")
        print("[UITEST] tap opened the full player")
        shot(app, "2-after-tap")

        // The close button sits below the status bar now: it must be hittable.
        XCTAssertTrue(close.isHittable, "the full player's close button can't be tapped")
        close.tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 10), "closing didn't bring the mini player back")
        sleep(1)

        // 2. Swipe up.
        mini.swipeUp()
        XCTAssertTrue(close.waitForExistence(timeout: 10), "swiping up on the mini player didn't open the full player")
        print("[UITEST] swipe up opened the full player")
        shot(app, "3-after-swipe")
        close.tap()
        sleep(1)

        // 3. The tab bar.
        let search = app.buttons["Buscar"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "no native tab bar")
        search.tap()
        let searchField = app.webViews.searchFields.firstMatch
        let searchBox = app.webViews.textFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8) || searchBox.exists, "the Buscar tab didn't open search")
        print("[UITEST] tab bar opened search")
        shot(app, "4-search")

        app.buttons["Inicio"].tap()
        sleep(3)
        shot(app, "5-home")
    }
}
