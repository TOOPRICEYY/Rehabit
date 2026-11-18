import XCTest

/// Round two of the injury screens on demo data: the new injury form's
/// suggestions, the chart's weight moved, the report's period and the body
/// map with no usual week yet.
final class InjuryRoundTwoTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        executionTimeAllowance = 240
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "injury2-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ argument: String = "-demo-workout") -> XCUIApplication {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = [argument]
        app.launch()
        return app
    }

    private func clear(_ field: XCUIElement) {
        guard let text = field.value as? String, !text.isEmpty else { return }
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count + 2))
    }

    func testNewInjurySuggestions() {
        let app = launch()
        app.tabBars.buttons["Injuries"].tap()
        app.navigationBars.buttons["Add injury"].tap()
        let name = app.textFields["Name, such as Left pec strain"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let save = app.navigationBars.buttons["Save"]
        XCTAssertFalse(save.isEnabled)
        shot("01-form-empty")

        name.tap()
        name.typeText("right rotator cuff")
        let right = app.buttons["Right"].firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 2))
        XCTAssertTrue(right.isSelected, "the name's side is preselected")
        XCTAssertFalse(app.buttons["Left"].firstMatch.isSelected)
        let chip = app.buttons["Add suggested tissue Rotator cuff"]
        XCTAssertTrue(chip.exists, "the suggested tissue is offered")
        XCTAssertFalse(save.isEnabled, "a suggested tissue is not added by itself")
        shot("02-right-rotator-cuff")
        chip.tap()
        XCTAssertFalse(chip.exists)
        // A new injury also needs the date it began.
        XCTAssertFalse(save.isEnabled, "Save waits for a date")
        app.buttons["Pick the date it began"].tap()
        let use = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Use '")).firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 3))
        use.tap()
        XCTAssertTrue(save.isEnabled)
        shot("03-chip-added")

        // A name with no side word: no side is chosen, and Save waits for one.
        clear(name)
        name.typeText("pec strain")
        sleep(1)
        XCTAssertFalse(app.buttons["Right"].firstMatch.isSelected)
        XCTAssertFalse(app.buttons["Left"].firstMatch.isSelected)
        XCTAssertFalse(app.buttons["Both"].firstMatch.isSelected)
        XCTAssertTrue(app.staticTexts["Choose a side to save."].exists)
        let pec = app.buttons["Add suggested tissue Pectoralis major"]
        XCTAssertTrue(pec.exists)
        pec.tap()
        XCTAssertFalse(save.isEnabled, "Save stays off until a side is picked")
        shot("04-no-side")
        app.buttons["Left"].firstMatch.tap()
        XCTAssertTrue(save.isEnabled)
        shot("05-side-picked")
        save.tap()
        let saved = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'pec strain'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 3))
        shot("06-saved")

        // Editing keeps the side already chosen.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Left quad strain'")).firstMatch.tap()
        app.navigationBars.buttons["Edit"].tap()
        XCTAssertTrue(app.buttons["Left"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Left"].firstMatch.isSelected)
        XCTAssertTrue(app.navigationBars.buttons["Save"].isEnabled)
        shot("07-edit-existing")
        app.navigationBars.buttons["Cancel"].tap()
    }

    func testChartWeightMovedAndReport() {
        let app = launch()
        app.tabBars.buttons["Injuries"].tap()
        let quad = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Left quad strain'")).firstMatch
        XCTAssertTrue(quad.waitForExistence(timeout: 3))
        quad.tap()
        sleep(1)
        let weight = app.buttons["Weight moved"]
        for _ in 0..<4 where !weight.isHittable { app.swipeUp() }
        sleep(1)
        shot("10-chart-effective-reps")
        weight.tap()
        XCTAssertTrue(weight.isSelected)
        sleep(1)
        shot("11-chart-weight-moved")
        app.buttons["12 weeks"].firstMatch.tap()
        sleep(1)
        shot("12-chart-12-weeks")

        let report = app.buttons["Report for your therapist"]
        for _ in 0..<3 where !report.isHittable { app.swipeUp() }
        report.tap()
        let twelve = app.buttons["12 weeks"].firstMatch
        XCTAssertTrue(twelve.waitForExistence(timeout: 3))
        twelve.tap()
        XCTAssertTrue(twelve.isSelected)
        sleep(1)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '84 days'")).firstMatch.exists)
        shot("13-report-12-weeks")
        app.swipeUp()
        sleep(1)
        shot("14-report-12-weeks-more")
    }

    func testBodyMapWithoutHistory() {
        let app = launch("-demo-empty")
        app.tabBars.buttons["Load"].tap()
        let body = app.segmentedControls.buttons["Body"]
        if body.waitForExistence(timeout: 5) { body.tap() }
        let line = app.staticTexts["Not enough history yet to compare with a usual week"]
        XCTAssertTrue(line.waitForExistence(timeout: 3))
        XCTAssertTrue(app.segmentedControls.buttons["This week"].isSelected, "This week is shown first")
        shot("20-body-no-history")
        app.segmentedControls.buttons["Versus usual"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["Versus usual"].isSelected, "the person can still switch")
        XCTAssertTrue(line.exists)
        sleep(1)
        shot("21-body-no-history-versus-usual")
    }
}
