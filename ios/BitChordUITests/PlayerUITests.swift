import XCTest

/// Real touches on the app, as a finger would: the mini player must open the full player,
/// by a tap and by a swipe up. (Run on the simulator by .github/workflows/ios.yml.)
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

    func testMiniPlayerOpensFullScreenPlayer() throws {
        let app = XCUIApplication()
        // -autotest starts a Debug-page track by itself after a few seconds.
        app.launchArguments = ["-route", "/debug", "-autotest"]
        app.launch()

        let mini = app.webViews.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Now playing'")).firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 60), "the mini player never appeared")
        shot(app, "1-mini-player")

        // 1. Tap.
        mini.tap()
        let close = app.webViews.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "tapping the mini player didn't open the full player")
        XCTAssertFalse(app.webViews.staticTexts["The player couldn’t open"].exists, "the full player failed to render")
        print("[UITEST] tap opened the full player")
        shot(app, "2-after-tap")

        close.tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 10), "closing didn't bring the mini player back")
        sleep(1)

        // 2. Swipe up.
        let start = mini.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -220))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(close.waitForExistence(timeout: 10), "swiping up on the mini player didn't open the full player")
        print("[UITEST] swipe up opened the full player")
        shot(app, "3-after-swipe")
    }
}
