import XCTest

/// Round three of the progress screens, on demo data: a load chart for a
/// high-rep exercise, the week card, and weight moved per side on the body map.
final class ProgressRoundThreeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        executionTimeAllowance = 240
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "progress3-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ extra: [String] = [], dark: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.appearance = dark ? .dark : .light
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout"] + extra
        app.launch()
        // Set again once running: set only before launch it does not always take.
        XCUIDevice.shared.appearance = dark ? .dark : .light
        sleep(1)
        return app
    }

    private func openCalfRaise(_ app: XCUIApplication) {
        app.tabBars.buttons["Workouts"].tap()
        let exercises = app.buttons["Exercises"]
        for _ in 0..<4 where !exercises.isHittable { app.swipeUp() }
        XCTAssertTrue(exercises.waitForExistence(timeout: 5))
        exercises.tap()
        let calf = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Single-Leg Calf Raise'")).firstMatch
        XCTAssertTrue(calf.waitForExistence(timeout: 5))
        calf.tap()
        sleep(1)
    }

    func testHighRepExerciseShowsLoadChart() {
        let app = launch()
        openCalfRaise(app)
        XCTAssertTrue(app.staticTexts["Top load"].waitForExistence(timeout: 3) || app.staticTexts["TOP LOAD"].exists)
        XCTAssertFalse(app.staticTexts["Longest hold"].exists)
        XCTAssertFalse(app.staticTexts["LONGEST HOLD"].exists)
        shot("01-calf-raise")
        app.swipeUp()
        sleep(1)
        shot("02-calf-raise-more")
    }

    func testHighRepExerciseLargestText() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"], dark: true)
        openCalfRaise(app)
        shot("03-calf-raise-dark-large")
        XCUIDevice.shared.appearance = .light
    }

    func testWeekCard() {
        let app = launch()
        app.tabBars.buttons["Workouts"].tap()
        sleep(1)
        shot("10-week-card-no-effort")
        // Finish the demo's workout in progress with an effort, so the week has a session load.
        app.buttons["Resume workout"].firstMatch.tap()
        let finish = app.navigationBars.buttons["Finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tap()
        let keep = app.buttons["Keep them"]
        if keep.waitForExistence(timeout: 3) { keep.tap() }
        XCTAssertTrue(app.navigationBars["How hard was that session?"].waitForExistence(timeout: 6))
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Effort 7'")).firstMatch.tap()
        app.buttons["effort-save"].tap()
        let checks = app.navigationBars["How does it feel?"]
        if checks.waitForExistence(timeout: 6), checks.buttons["Done"].exists { checks.buttons["Done"].tap() }
        XCTAssertTrue(app.buttons["Start workout"].waitForExistence(timeout: 5))
        let load = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Session load'")).firstMatch
        XCTAssertTrue(load.waitForExistence(timeout: 3))
        for _ in 0..<3 where !load.isHittable { app.swipeUp() }
        sleep(1)
        shot("11-week-card-session-load")
    }

    private func openLeftQuads(_ app: XCUIApplication) {
        app.tabBars.buttons["Load"].tap()
        let body = app.segmentedControls.buttons["Body"]
        if body.waitForExistence(timeout: 5) { body.tap() }
        sleep(1)
        let quad = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Left quadriceps'")).firstMatch
        XCTAssertTrue(quad.waitForExistence(timeout: 5))
        quad.tap()
        sleep(1)
    }

    func testTissueSheetShowsWeightMoved() {
        let app = launch()
        openLeftQuads(app)
        shot("20-left-quads")
        app.swipeUp()
        sleep(1)
        let header = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Weight moved, last 7 days'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Left, injured"].exists)
        shot("21-left-quads-weight-moved")
    }

    func testTissueSheetDark() {
        let app = launch(dark: true)
        openLeftQuads(app)
        app.swipeUp()
        sleep(1)
        shot("22-left-quads-dark")
        XCUIDevice.shared.appearance = .light
    }
}
