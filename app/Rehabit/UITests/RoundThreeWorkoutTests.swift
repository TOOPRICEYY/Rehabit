import XCTest

/// Tempo, a note kept with an exercise, choosing the kind of set from the menu, and a timed hold.
final class RoundThreeWorkoutTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "workout3-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    private func open() -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout"]
        app.launch()
        app.buttons["Resume workout"].tap()
        XCTAssertTrue(app.staticTexts["Goblet Squat (Dumbbell)"].waitForExistence(timeout: 5))
        return app
    }

    private func any(_ app: XCUIApplication, _ format: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: format)).firstMatch
    }

    func testTempoKindAndExerciseNote() {
        let app = open()
        // Long press on set 1 of the squat: the set menu.
        any(app, "label == 'Set 1, Working set'").press(forDuration: 1.0)
        app.buttons["Tempo…"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("3-1-1-0")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(any(app, "label BEGINSWITH 'tempo 3-1-1-0'").waitForExistence(timeout: 3))
        shot("01-tempo")

        any(app, "label == 'Set 1, Working set'").press(forDuration: 1.0)
        app.buttons["Drop set"].tap()
        XCTAssertTrue(any(app, "label ENDSWITH ', Drop set'").waitForExistence(timeout: 3))

        any(app, "label == 'Options for Goblet Squat (Dumbbell)'").tap()
        app.buttons["Note for this exercise…"].tap()
        let note = app.alerts.textFields.firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 3))
        note.typeText("Heels on plates")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(any(app, "label == 'Heels on plates'").waitForExistence(timeout: 3))
        shot("02-note-and-drop")
    }

    func testTimedHoldCountsDownAndSaves() {
        let app = open()
        any(app, "label == 'Options for Goblet Squat (Dumbbell)'").tap()
        app.buttons["Sets are"].tap()
        app.buttons["Isometric holds"].tap()
        let timer = app.buttons["Time the hold"].firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 3))
        timer.tap()
        app.buttons["Start"].tap()
        sleep(2)
        shot("03-holding")
        app.buttons["Stop"].firstMatch.tap()
        let held = app.textFields.matching(NSPredicate(format: "label ENDSWITH 'seconds held'")).firstMatch
        XCTAssertTrue(held.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(Double((held.value as? String) ?? "") ?? 0, 1.5)
        shot("04-hold-saved")
    }
}
