import XCTest

/// Check-ins as one round, logging pain, and the progress screens, on demo data.
final class RoundOneTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        executionTimeAllowance = 200
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "round1-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch() -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout"]
        app.launch()
        return app
    }

    func testCheckInRoundAndLogPain() {
        let app = launch()
        app.tabBars.buttons["Check-ins"].tap()
        sleep(1)
        shot("01-round")
        let two = app.buttons["Pain 2"].firstMatch
        if two.waitForExistence(timeout: 3) {
            two.tap()
            shot("02-picked")
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Save'")).firstMatch.tap()
            sleep(1)
            shot("03-saved")
        }
        app.navigationBars.buttons["Log pain now"].tap()
        XCTAssertTrue(app.navigationBars["Log pain now"].waitForExistence(timeout: 3))
        app.buttons["Pain 3"].firstMatch.tap()
        let context = app.textFields.firstMatch
        context.tap()
        context.typeText("stairs")
        shot("04-log-pain")
        app.navigationBars.buttons["Save"].tap()
        sleep(1)
        shot("05-after-log")
    }

    func testProgressScreens() {
        let app = launch()
        app.tabBars.buttons["Workouts"].tap()
        sleep(1)
        shot("10-week")
        app.buttons["Exercises"].tap()
        sleep(1)
        shot("11-exercises")
        let ext = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Single-Leg Extension'")).firstMatch
        if ext.waitForExistence(timeout: 3) { ext.tap() }
        sleep(1)
        shot("12-history")
        app.swipeUp()
        sleep(1)
        shot("13-history-more")

        app.tabBars.buttons["Injuries"].tap()
        let quad = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Left quad strain'")).firstMatch
        if quad.waitForExistence(timeout: 3) { quad.tap() }
        sleep(1)
        app.swipeUp()
        sleep(1)
        shot("14-injury-left-right")

        app.tabBars.buttons["Workouts"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        let lowerA = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lower A'")).firstMatch
        if lowerA.waitForExistence(timeout: 3) { lowerA.tap() }
        sleep(1)
        shot("15-settled")
    }
}
