import XCTest

/// Pain on a set of an imported workout, in Edit.
final class ImportedPainTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        executionTimeAllowance = 200
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "imported-pain-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    func testPainOnAnImportedSet() {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout", "-demo-file", "-demo-reset"]
        app.launch()
        app.tabBars.buttons["Workouts"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Push day'")).firstMatch
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.staticTexts["Imported from Hevy"].waitForExistence(timeout: 5))
        shot("01-read-only")
        app.navigationBars.buttons["Edit"].tap()
        sleep(1)
        let chip = app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH ', pain'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 3), "a pain chip is offered")
        shot("02-editing")
        chip.tap()
        sleep(1)
        shot("03-after-tap")
        let three = app.buttons["3"].firstMatch
        XCTAssertTrue(three.waitForExistence(timeout: 3), "the pain picker opens")
        three.tap()
        sleep(1)
        shot("04-picked")
        XCTAssertEqual(chip.value as? String, "3 out of 10")
    }

    /// Without Edit: pain is recorded straight from the finished workout and is
    /// still there after leaving and reopening it.
    func testPainWithoutEditStaysAfterReopening() {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout", "-demo-file", "-demo-reset"]
        app.launch()
        app.tabBars.buttons["Workouts"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Push day'")).firstMatch
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.staticTexts["Imported from Hevy"].waitForExistence(timeout: 5))
        let chip = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Set 1' AND label ENDSWITH ', pain'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 3), "pain can be recorded without Edit")
        XCTAssertEqual(chip.value as? String, "not recorded")
        let summaryBefore = app.staticTexts.allElementsBoundByIndex.map(\.label)
        chip.tap()
        let four = app.buttons["4"].firstMatch
        XCTAssertTrue(four.waitForExistence(timeout: 3))
        four.tap()
        sleep(1)
        shot("10-read-only-picked")
        XCTAssertEqual(chip.value as? String, "4 out of 10")
        // Nothing else changed by accident.
        XCTAssertFalse(app.textFields.firstMatch.exists, "still read-only")
        let summaryAfter = app.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(Set(summaryBefore).subtracting(summaryAfter), [], "the set's numbers are as they were")

        // Leave and come back: the app is closed and opened again on the same file.
        app.terminate()
        let again = XCUIApplication()
        again.launchArguments = ["-demo-workout", "-demo-file"]
        again.launch()
        again.tabBars.buttons["Workouts"].tap()
        let row2 = again.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Push day'")).firstMatch
        for _ in 0..<6 where !(row2.exists && row2.isHittable) { again.swipeUp() }
        row2.tap()
        let chip2 = again.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Set 1' AND label ENDSWITH ', pain'")).firstMatch
        XCTAssertTrue(again.staticTexts["Imported from Hevy"].waitForExistence(timeout: 5))
        XCTAssertEqual(chip2.value as? String, "4 out of 10", "kept after reopening")
        shot("11-reopened")
    }
}
