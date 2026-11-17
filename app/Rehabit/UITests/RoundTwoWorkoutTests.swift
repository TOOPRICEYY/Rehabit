import XCTest

/// Set kinds, a done mark refused without reps, and supersets, on the demo workout.
final class RoundTwoWorkoutTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "workout2-" + name
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

    func testTappingTheNumberCyclesTheKindOfSet() {
        let app = open()
        let badge = any(app, "label == 'Set 1, Working set'")
        XCTAssertTrue(badge.waitForExistence(timeout: 3))
        badge.tap()                                   // working -> warm-up
        XCTAssertTrue(any(app, "label ENDSWITH ', Warm-up'").waitForExistence(timeout: 3))
        any(app, "label ENDSWITH ', Warm-up'").tap()  // warm-up -> drop set
        XCTAssertTrue(any(app, "label ENDSWITH ', Drop set'").waitForExistence(timeout: 3))
        shot("01-drop-set")
        any(app, "label ENDSWITH ', Drop set'").tap() // drop -> to failure
        XCTAssertTrue(any(app, "label ENDSWITH ', To failure'").waitForExistence(timeout: 3))
        shot("02-to-failure")
    }

    func testDoneIsRefusedWithoutReps() {
        let app = open()
        let reps = app.textFields["Set 1, Goblet Squat (Dumbbell), reps"].firstMatch
        XCTAssertTrue(reps.waitForExistence(timeout: 3))
        reps.tap()
        reps.typeText(XCUIKeyboardKey.delete.rawValue)
        let keyDone = app.toolbars.buttons["Done"].firstMatch
        if keyDone.exists { keyDone.tap() }
        any(app, "label == 'Set 1, Goblet Squat (Dumbbell) done'").tap()
        XCTAssertTrue(app.staticTexts["Enter reps first"].waitForExistence(timeout: 3))
        XCTAssertEqual(any(app, "label == 'Set 1, Goblet Squat (Dumbbell) done'").value as? String, "not done")
        shot("03-enter-reps-first")
    }

    func testSupersetJoinsCardsAndSaysWhatIsNext() {
        let app = open()
        any(app, "label == 'Options for Goblet Squat (Dumbbell)'").tap()
        app.buttons["Superset with…"].tap()
        let other = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Single-Leg Extension (Machine)'")).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        shot("04a-superset-picker")
        other.tap()
        app.navigationBars.buttons["Save"].tap()
        XCTAssertTrue(any(app, "label BEGINSWITH 'Superset with Single-Leg Extension'").waitForExistence(timeout: 3))
        shot("04-superset")
        any(app, "label == 'Set 1, Goblet Squat (Dumbbell) done'").tap()
        XCTAssertTrue(any(app, "label == 'Next: Single-Leg Extension (Machine)'").waitForExistence(timeout: 3))
        shot("05-next")
    }
}
