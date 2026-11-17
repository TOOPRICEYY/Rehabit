import XCTest

/// Records prepared on the Mac: the card, the review sheet and "Add all", with made-up injuries.
final class InboxTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        executionTimeAllowance = 120
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "inbox-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    func testReviewAndAddAll() {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout", "-demo-inbox"]
        app.launch()
        app.tabBars.buttons["Injuries"].tap()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS 'injuries are waiting'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        shot("01-card")
        card.tap()
        XCTAssertTrue(app.buttons["Add all"].waitForExistence(timeout: 5))
        sleep(1)
        shot("02-review")
        app.buttons["Add all"].tap()
        sleep(1)
        XCTAssertTrue(app.staticTexts["Right hamstring strain"].waitForExistence(timeout: 5))
        XCTAssertFalse(card.exists)
        shot("03-added")
    }

    func testNotNowKeepsTheCard() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout", "-demo-inbox"]
        app.launch()
        app.tabBars.buttons["Injuries"].tap()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS 'injuries are waiting'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        app.buttons["Not now"].tap()
        sleep(1)
        XCTAssertTrue(card.exists)
        XCTAssertFalse(app.staticTexts["Right hamstring strain"].exists)
    }
}
