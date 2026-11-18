import XCTest

/// Done marks, rest, steps, hold timer and units, on the demo workout.
final class RoundOneBatchTwoTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        executionTimeAllowance = 200
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "round1b-" + name
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

    private func any(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testDoneRestSkipAndFinishPrompt() {
        let app = open()
        any(app, "Set 1, Goblet Squat (Dumbbell) done").tap()
        let rest = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Rest'")).firstMatch
        XCTAssertTrue(rest.waitForExistence(timeout: 3))
        shot("01-done-and-rest")
        app.buttons["Skip"].tap()
        XCTAssertTrue(app.staticTexts["Since last set"].waitForExistence(timeout: 3))
        app.navigationBars.buttons["Finish"].tap()
        let keep = app.buttons["Keep them"]
        XCTAssertTrue(keep.waitForExistence(timeout: 3))
        shot("02-finish-prompt")
        keep.tap()
    }

    func testStepperAddsTheLoadStep() {
        let app = open()
        let weight = app.textFields["Set 1, Goblet Squat (Dumbbell), pounds"].firstMatch
        XCTAssertEqual(weight.value as? String, "40")
        weight.tap()
        let plus = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Plus'")).firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 3))
        shot("03-step-bar")
        plus.tap()
        XCTAssertNotEqual(weight.value as? String, "40")
        shot("04-stepped")
    }

    func testHoldTimerWritesSeconds() {
        let app = open()
        any(app, "Options for Goblet Squat (Dumbbell)").tap()
        app.buttons["Sets are"].tap()
        app.buttons["Isometric holds"].tap()
        let timer = app.buttons["Time the hold"].firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 3))
        timer.tap()
        app.buttons["Start"].tap()
        sleep(3)
        shot("05-holding")
        app.buttons["Stop"].firstMatch.tap()
        let held = app.textFields.matching(NSPredicate(format: "label ENDSWITH 'seconds held'")).firstMatch
        XCTAssertTrue(held.waitForExistence(timeout: 3))
        let seconds = Double((held.value as? String) ?? "") ?? 0
        XCTAssertGreaterThanOrEqual(seconds, 2.5)
        shot("06-hold-written")
    }

    func testUnitConversion() {
        let app = open()
        any(app, "Options for Goblet Squat (Dumbbell)").tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Unit'")).firstMatch.tap()
        app.buttons["Convert to kg, exact"].tap()
        sleep(1)
        let weight = app.textFields["Set 1, Goblet Squat (Dumbbell), kilograms"].firstMatch
        XCTAssertTrue(weight.waitForExistence(timeout: 3))
        let kg = Double((weight.value as? String) ?? "") ?? 0
        XCTAssertEqual(kg, 18.1, accuracy: 0.6)
        shot("07-kg")
    }
}
