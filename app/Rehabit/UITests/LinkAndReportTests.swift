import XCTest

/// The third way to link sides (reps only) and one report for every injury still healing.
final class LinkAndReportTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "link-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    private func any(_ app: XCUIApplication, _ format: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format)).firstMatch
    }

    func testLinkRepsOnly() {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout"]
        app.launch()
        app.buttons["Resume workout"].tap()
        // The leg extension loads the injured left, so its sides start separate.
        let separate = any(app, "label == 'Sides separate'")
        for _ in 0..<6 where !(separate.exists && separate.isHittable) { app.swipeUp() }
        if separate.exists && separate.frame.minY > 550 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -250)))
        }
        XCTAssertTrue(separate.waitForExistence(timeout: 5))
        separate.tap()
        let repsOnly = any(app, "label == 'Link reps only'")
        XCTAssertTrue(repsOnly.waitForExistence(timeout: 3))
        shot("01-menu")
        repsOnly.tap()
        // Reps only copies no weight, so no warning about the injured side.
        XCTAssertFalse(app.buttons["Link anyway"].waitForExistence(timeout: 2))
        let linked = any(app, "label == 'Reps linked'")
        XCTAssertTrue(linked.waitForExistence(timeout: 3))
        shot("02-reps-linked")
        // Linking the weight too still warns.
        linked.tap()
        any(app, "label == 'Link reps and weight'").tap()
        XCTAssertTrue(app.buttons["Link anyway"].waitForExistence(timeout: 3))
        shot("03-warning")
        app.buttons["Link anyway"].tap()
        XCTAssertTrue(any(app, "label == 'Sides linked'").waitForExistence(timeout: 3))
    }

    func testReportForAllInjuries() {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout"]
        app.launch()
        app.tabBars.buttons["Injuries"].tap()
        let all = app.buttons["Report for all injuries"]
        XCTAssertFalse(all.exists, "one injury has its own report")
        app.navigationBars.buttons["Add injury"].tap()
        let name = app.textFields["Name, such as Left pec strain"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("right rotator cuff")
        app.buttons["Add suggested tissue Rotator cuff"].tap()
        app.buttons["Pick the date it began"].tap()
        let use = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Use '")).firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 3))
        use.tap()
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        shot("10-all-injuries-row")
        all.tap()
        sleep(2)
        shot("11-share-sheet")
    }

    /// The first set marked done used to freeze the screen for about 30 s while
    /// the rest notification was replaced on the main thread.
    func testFirstDoneMarkIsQuick() {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout"]
        app.launch()
        app.buttons["Resume workout"].tap()
        let done = any(app, "label == 'Set 1, Goblet Squat (Dumbbell) done'")
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        let start = Date()
        done.tap()
        let rest = any(app, "label CONTAINS 'Rest'")
        XCTAssertTrue(rest.waitForExistence(timeout: 8))
        XCTAssertLessThan(Date().timeIntervalSince(start), 8, "the screen answers at once")
        // And the screen still takes taps straight away.
        let start2 = Date()
        app.navigationBars.buttons["Finish"].tap()
        XCTAssertLessThan(Date().timeIntervalSince(start2), 8)
        shot("20-first-done")
    }
}
