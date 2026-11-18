import XCTest

/// Round three on demo data: a plan for an injury (the limits and milestones
/// the person or their therapist set) and the new injury form asking for a date.
final class InjuryPlanTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        executionTimeAllowance = 300
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "plan-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(dark: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.appearance = dark ? .dark : .light
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout"]
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, up: Bool = true) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            if up { app.swipeUp() } else { app.swipeDown() }
        }
    }

    /// The pain chip on the sheet in front: the sheet behind has the same chips.
    private func chip(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let all = app.buttons.matching(identifier: label).allElementsBoundByIndex
        return all.last { $0.isHittable } ?? all.last ?? app.buttons[label]
    }

    private func any(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func openQuad(_ app: XCUIApplication) {
        app.tabBars.buttons["Injuries"].tap()
        let quad = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Left quad strain'")).firstMatch
        XCTAssertTrue(quad.waitForExistence(timeout: 5))
        quad.tap()
    }

    func testAddPlanAndTickMilestone() {
        let app = launch()
        openQuad(app)
        let empty = app.staticTexts["No plan yet. Add the limits and milestones you or your therapist set."]
        reveal(empty, in: app)
        XCTAssertTrue(empty.exists, "the empty plan says what to add")
        shot("01-no-plan")
        app.buttons["Add a plan"].tap()
        XCTAssertTrue(app.navigationBars["Plan"].waitForExistence(timeout: 3))
        shot("02-editor-empty")

        app.buttons["My physical therapist"].tap()
        XCTAssertTrue(app.buttons["My physical therapist"].isSelected)
        app.buttons["Pain 3"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No higher than 3 out of 10."].exists)
        let hours = app.textFields["Settle within, hours"]
        hours.tap()
        hours.typeText("24")
        shot("03-editor-limits")

        // A milestone with an exercise.
        let add = app.buttons["Add milestone"]
        reveal(add, in: app)
        add.tap()
        let title = app.textFields["Title, such as Stairs without the rail"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.typeText("Extension at 25")
        app.buttons["Choose an exercise"].tap()
        let leg = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Single-Leg Extension'")).firstMatch
        XCTAssertTrue(leg.waitForExistence(timeout: 3))
        leg.tap()
        XCTAssertTrue(app.buttons["Change exercise"].waitForExistence(timeout: 3), "the exercise is chosen")
        let load = app.textFields["Load, at least"]
        load.tap()
        load.typeText("25")
        let reps = app.textFields["Reps, at least"]
        reps.tap()
        reps.typeText("10")
        app.staticTexts["What a set needs"].firstMatch.tap()      // puts the number pad away
        let two = chip("Pain 2", in: app)
        reveal(two, in: app)
        two.tap()
        XCTAssertTrue(app.staticTexts["2 or less. A set with no pain recorded does not count."].waitForExistence(timeout: 2))
        shot("04-milestone-exercise")
        app.navigationBars.buttons["Done"].tap()

        // One ticked by hand.
        reveal(add, in: app)
        add.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        title.tap()
        title.typeText("Stairs without the rail")
        shot("05-milestone-by-hand")
        app.navigationBars.buttons["Done"].tap()

        let visit = app.switches["Next visit booked"]
        reveal(visit, in: app)
        visit.switches.firstMatch.tap()
        shot("06-editor-filled")
        app.navigationBars.buttons["Save"].tap()

        // Back on the injury: the plan, sessions against the limits, milestones.
        let limits = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'no higher than 3'")).firstMatch
        reveal(limits, in: app)
        XCTAssertTrue(limits.exists, "the limits are shown in words")
        XCTAssertTrue(any(app, containing: "My physical therapist").exists)
        shot("07-plan-section")
        let rows = app.descendants(matching: .any).matching(identifier: "rule-check")
        let firstRow = rows.firstMatch
        reveal(firstRow, in: app)
        XCTAssertTrue(firstRow.exists, "a session is shown against the limits")
        shot("08-rule-rows")
        let stairs = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Stairs without the rail'")).firstMatch
        reveal(stairs, in: app)
        XCTAssertTrue(stairs.exists)
        XCTAssertTrue(any(app, containing: "Single-Leg Extension (Machine): 25 lb x 10, pain 2 or less").exists)
        shot("09-milestones")
        XCTAssertFalse(stairs.isSelected)
        stairs.tap()
        let ticked = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Stairs without the rail' AND label CONTAINS 'Ticked on'")).firstMatch
        XCTAssertTrue(ticked.waitForExistence(timeout: 3), "ticking by hand records the day")
        XCTAssertTrue(ticked.isSelected)
        shot("10-milestone-ticked")

        // Opening the editor again keeps what was saved.
        let edit = app.buttons["Edit plan"]
        reveal(edit, in: app, up: false)
        edit.tap()
        XCTAssertTrue(app.buttons["My physical therapist"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["My physical therapist"].isSelected)
        XCTAssertTrue(app.staticTexts["No higher than 3 out of 10."].exists)
        app.navigationBars.buttons["Cancel"].tap()
    }

    func testPlanInDarkMode() {
        let app = launch(dark: true)
        openQuad(app)
        let add = app.buttons["Add a plan"]
        reveal(add, in: app)
        add.tap()
        app.buttons["Me"].tap()
        XCUIDevice.shared.appearance = .dark
        app.buttons["Pain 4"].firstMatch.tap()
        let hours = app.textFields["Settle within, hours"]
        hours.tap()
        hours.typeText("48")
        shot("20-dark-editor")
        app.navigationBars.buttons["Save"].tap()
        let firstRow = app.descendants(matching: .any).matching(identifier: "rule-check").firstMatch
        reveal(firstRow, in: app)
        sleep(1)
        shot("21-dark-plan")
    }

    func testNewInjuryNeedsADate() {
        let app = launch()
        app.tabBars.buttons["Injuries"].tap()
        app.navigationBars.buttons["Add injury"].tap()
        let name = app.textFields["Name, such as Left pec strain"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("right rotator cuff")
        let chip = app.buttons["Add suggested tissue Rotator cuff"]
        XCTAssertTrue(chip.waitForExistence(timeout: 2))
        chip.tap()
        let save = app.navigationBars.buttons["Save"]
        XCTAssertFalse(save.isEnabled, "no date picked: Save waits")
        let pick = app.buttons["Pick the date it began"]
        XCTAssertTrue(pick.exists, "the form asks for the date instead of assuming today")
        shot("30-new-no-date")
        pick.tap()
        let use = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Use '")).firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 3))
        XCTAssertFalse(save.isEnabled)
        shot("31-new-picking")
        use.tap()
        XCTAssertTrue(save.isEnabled, "a picked date lets it save")
        XCTAssertTrue(app.buttons["Date is known to the"].exists || app.staticTexts["Date is known to the"].exists,
                      "the precision control stays")
        shot("32-new-date-picked")
        app.navigationBars.buttons["Cancel"].tap()

        // Editing an existing injury keeps its date.
        let quad = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Left quad strain'")).firstMatch
        quad.tap()
        app.navigationBars.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Edit injury"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Pick the date it began"].exists)
        XCTAssertTrue(app.navigationBars.buttons["Save"].isEnabled)
        shot("33-edit-keeps-date")
        app.navigationBars.buttons["Cancel"].tap()
    }
}
