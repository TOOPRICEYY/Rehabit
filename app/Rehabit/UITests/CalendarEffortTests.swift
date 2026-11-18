import XCTest

/// Round three: how hard a session was, the history calendar, and a routine
/// item's target and tempo, on demo data.
final class CalendarEffortTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "cal-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(dark: Bool = false, extra: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.appearance = dark ? .dark : .light
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout"] + extra
        app.launch()
        app.tabBars.buttons["Workouts"].tap()
        return app
    }

    private func any(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func containing(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement) {
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
    }

    /// Finishes the demo's workout in progress, keeping its sets.
    private func finishDemoWorkout(_ app: XCUIApplication) {
        app.buttons["Resume workout"].firstMatch.tap()
        let finish = app.navigationBars.buttons["Finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tap()
        let keep = app.buttons["Keep them"]
        if keep.waitForExistence(timeout: 15) { keep.tap() }
    }

    /// Closes the pain questions shown after a workout, answering one if asked.
    private func closeCheckIns(_ app: XCUIApplication, answer pain: String? = nil) {
        let checks = app.navigationBars["How does it feel?"]
        XCTAssertTrue(checks.waitForExistence(timeout: 20))
        if let pain {
            any(app, "Pain \(pain)").tap()
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Save'")).firstMatch.tap()
        }
        if checks.buttons["Done"].exists { checks.buttons["Done"].tap() }
        XCTAssertTrue(app.buttons["Start workout"].waitForExistence(timeout: 5))
    }

    private func openFinished(_ app: XCUIApplication, _ title: String) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        scrollTo(app, row)
        row.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    // MARK: Effort

    func testEffortAskedSavedAndEdited() {
        let app = launch()
        finishDemoWorkout(app)
        let prompt = app.staticTexts["effort-question"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 20))
        shot("01-effort-prompt")
        any(app, "Effort 6.5").tap()
        shot("02-effort-chosen")
        app.buttons["effort-save"].tap()
        closeCheckIns(app)

        openFinished(app, "Lower B")
        XCTAssertTrue(app.staticTexts["Effort 6.5 of 10"].waitForExistence(timeout: 3))
        shot("03-finished-effort")
        app.navigationBars.buttons["Edit"].tap()
        any(app, "Effort 8").tap()
        XCTAssertTrue(app.staticTexts["How hard it was: 8 of 10"].waitForExistence(timeout: 3))
        shot("04-finished-edit-effort")
        app.navigationBars.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Effort 8 of 10"].waitForExistence(timeout: 3))
    }

    func testEffortSkippedInDark() {
        let app = launch(dark: true)
        finishDemoWorkout(app)
        let prompt = app.staticTexts["effort-question"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 20))
        shot("05-effort-prompt-dark")
        app.navigationBars["Session effort"].buttons["Skip"].tap()
        closeCheckIns(app)
        openFinished(app, "Lower B")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Effort'")).firstMatch.exists)
        shot("06-finished-no-effort-dark")
    }

    func testEffortNotAskedWhenTurnedOff() {
        let app = launch()
        app.tabBars.buttons["Settings"].tap()
        let toggle = app.switches["Ask how hard each session was"]
        scrollTo(app, toggle)
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        shot("07-setting-off")
        app.tabBars.buttons["Workouts"].tap()
        finishDemoWorkout(app)
        XCTAssertTrue(app.navigationBars["How does it feel?"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.staticTexts["effort-question"].exists)
        shot("08-straight-to-checkins")
    }

    // MARK: Calendar

    func testCalendarShowsDaysAndOpensAWorkout() {
        let app = launch()
        // Today gets a session, an answered pain question and a flare-up.
        finishDemoWorkout(app)
        let prompt = app.staticTexts["effort-question"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 20))
        app.navigationBars["Session effort"].buttons["Skip"].tap()
        closeCheckIns(app, answer: "3")
        app.tabBars.buttons["Check-ins"].tap()
        app.buttons["Log pain now"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Log pain now"].waitForExistence(timeout: 3))
        any(app, "Pain 5").tap()
        app.navigationBars["Log pain now"].buttons["Save"].tap()
        app.tabBars.buttons["Workouts"].tap()

        let calendar = app.buttons["Calendar"]
        scrollTo(app, calendar)
        calendar.tap()
        XCTAssertTrue(app.staticTexts["calendar-month"].waitForExistence(timeout: 5))
        shot("10-calendar-month")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let today = app.buttons["calendar-day-\(formatter.string(from: Date()))"]
        XCTAssertTrue(today.exists)
        let label = today.label
        XCTAssertTrue(label.contains("2 sessions"), label)
        XCTAssertTrue(label.contains("pain 3"), label)
        XCTAssertTrue(label.contains("flare-up"), label)
        today.tap()
        let lowerB = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lower B'")).firstMatch
        scrollTo(app, lowerB)
        XCTAssertTrue(lowerB.waitForExistence(timeout: 3))
        shot("11-calendar-day")
        lowerB.tap()
        XCTAssertTrue(app.navigationBars["Lower B"].waitForExistence(timeout: 5))
        shot("12-calendar-workout")
        app.navigationBars.buttons.firstMatch.tap()

        app.swipeDown(); app.swipeDown()
        app.buttons["Previous month"].tap()
        shot("13-calendar-previous")
        XCTAssertTrue(app.buttons["Next month"].isEnabled)
        app.buttons["Next month"].tap()
        XCTAssertFalse(app.buttons["Next month"].isEnabled)
    }

    func testCalendarLargeTextDark() {
        let app = launch(dark: true, extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        let calendar = app.buttons["Calendar"]
        scrollTo(app, calendar)
        calendar.tap()
        XCTAssertTrue(app.staticTexts["calendar-month"].waitForExistence(timeout: 5))
        shot("14-calendar-large-dark")
    }

    // MARK: Routine target and tempo

    func testRoutineTargetAndTempo() {
        let app = launch()
        let routines = app.buttons["Routines"]
        routines.tap()
        let routine = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lower B'")).firstMatch
        XCTAssertTrue(routine.waitForExistence(timeout: 5))
        routine.tap()
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Goblet Squat'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()

        let target = app.textFields["routine-target"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        target.typeText("8")
        let tempo = app.textFields["routine-tempo"]
        tempo.tap()
        tempo.typeText("3-1")
        XCTAssertTrue(app.staticTexts["routine-tempo-invalid"].waitForExistence(timeout: 3))
        shot("20-tempo-invalid")
        tempo.typeText("x0")
        // "3-1x0" is not four phases; finish writing it as one.
        tempo.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "31x0")
        let tension = app.staticTexts["routine-tension"]
        XCTAssertTrue(tension.waitForExistence(timeout: 3))
        XCTAssertEqual(tension.label, "Saved as 3-1-X-0. Time under tension 32 s a set (4 s a rep).")
        tempo.typeText("\n")
        shot("21-tempo-valid")
        XCTAssertEqual(tempo.value as? String, "3-1-X-0")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(containing(app, "8 reps · tempo 3-1-X-0").waitForExistence(timeout: 3))
        shot("22-routine-summary")
        app.navigationBars.buttons["Save"].tap()
        routine.tap()
        XCTAssertTrue(containing(app, "tempo 3-1-X-0").waitForExistence(timeout: 3))
    }
}
