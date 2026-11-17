import XCTest

/// Routines: starting from one, saving a finished workout as one, repeating a
/// finished workout and changing a routine, on demo data.
final class RoutineTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        executionTimeAllowance = 230
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "routines-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch() -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout"]
        app.launch()
        app.tabBars.buttons["Workouts"].tap()
        return app
    }

    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The demo has a workout part way through; it is thrown away so another can start.
    private func discardActive(_ app: XCUIApplication) {
        app.buttons["Resume workout"].firstMatch.tap()
        let discard = app.navigationBars.buttons["Discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        app.buttons["Discard workout"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Start workout"].waitForExistence(timeout: 5))
    }

    private func clear(_ field: XCUIElement) {
        field.tap()
        let length = (field.value as? String)?.count ?? 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length + 2))
    }

    func testStartFromRoutine() {
        let app = launch()
        app.buttons["Routines"].tap()
        let start = app.buttons["Start Lower B"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        shot("01-list-while-active")
        start.tap()
        XCTAssertTrue(app.alerts["A workout is in progress"].waitForExistence(timeout: 3))
        shot("02-in-progress")
        app.alerts.buttons["OK"].tap()
        app.navigationBars.buttons.firstMatch.tap()

        discardActive(app)
        app.buttons["Routines"].tap()
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        shot("03-list")
        start.tap()
        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, containing: "Single-Leg Extension").waitForExistence(timeout: 3))
        shot("04-started")
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(element(app, containing: "Goblet Squat").waitForExistence(timeout: 3))
        shot("05-started-more")
    }

    func testSaveFinishedWorkoutAsRoutine() {
        let app = launch()
        let lowerA = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lower A'")).firstMatch
        if !lowerA.waitForExistence(timeout: 3) || !lowerA.isHittable { app.swipeUp() }
        lowerA.tap()
        app.buttons["More"].tap()
        shot("10-menu")
        app.buttons["Save as routine…"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "Lower A")
        clear(field)
        field.typeText("Leg day")
        shot("11-name")
        app.alerts.buttons["Save"].tap()
        // The first tap can land while the keyboard is still settling.
        if !app.alerts["Routine saved"].waitForExistence(timeout: 3), app.alerts.buttons["Save"].exists {
            app.alerts.buttons["Save"].tap()
        }
        XCTAssertTrue(app.alerts["Routine saved"].waitForExistence(timeout: 3))
        shot("12-saved")
        app.alerts.buttons["OK"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Routines"].tap()
        XCTAssertTrue(app.buttons["Start Leg day"].waitForExistence(timeout: 5))
        shot("13-in-list")
    }

    func testRepeatFinishedWorkout() {
        let app = launch()
        discardActive(app)
        let lowerA = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lower A'")).firstMatch
        if !lowerA.waitForExistence(timeout: 3) || !lowerA.isHittable { app.swipeUp() }
        lowerA.tap()
        app.buttons["More"].tap()
        app.buttons["Repeat this workout"].tap()
        XCTAssertTrue(app.navigationBars["Workout"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, containing: "Single-Leg Extension").waitForExistence(timeout: 3))
        shot("20-repeated")

        // The same from the history row's swipe action.
        app.navigationBars.buttons["Discard"].tap()
        app.buttons["Discard workout"].firstMatch.tap()
        let back = app.navigationBars.buttons["Workouts"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        sleep(1)
        back.tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lower A'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeRight()
        let again = app.buttons["Repeat"].firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 3))
        shot("21-swipe")
        again.tap()
        let opened = app.navigationBars["Workout"].waitForExistence(timeout: 5)
        shot("22-after-swipe-repeat")
        XCTAssertTrue(opened)
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(element(app, containing: "Goblet Squat").waitForExistence(timeout: 3))
    }

    func testEditRoutine() {
        let app = launch()
        app.buttons["Routines"].tap()
        let routine = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Lower B'")).firstMatch
        XCTAssertTrue(routine.waitForExistence(timeout: 5))
        routine.tap()
        let name = app.textFields["Routine name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        shot("30-editor")
        clear(name)
        name.typeText("Legs, light")
        let squat = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Goblet Squat'")).firstMatch
        squat.tap()
        let more = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Increment'")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        shot("31-item")
        more.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sides'")).firstMatch.tap()
        shot("32-sides")
        app.buttons["Each side"].firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(element(app, containing: "4 rounds · each side").waitForExistence(timeout: 3))
        shot("33-editor-changed")
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Start Legs, light"].waitForExistence(timeout: 5))
        shot("34-saved")

        // Saved: opening it again shows the change.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Legs, light'")).firstMatch.tap()
        XCTAssertTrue(element(app, containing: "4 rounds · each side").waitForExistence(timeout: 3))
        app.navigationBars.buttons["Cancel"].tap()

        // Dark mode, for a look.
        XCUIDevice.shared.appearance = .dark
        sleep(1)
        shot("35-dark")
    }
}
