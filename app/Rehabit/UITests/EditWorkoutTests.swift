import XCTest

/// Editing a finished, imported workout: side, weight, a new set, a new name,
/// and that all of it is still there after the app is relaunched.
final class EditWorkoutTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        executionTimeAllowance = 150
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "edit-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    private func openPushDay(_ app: XCUIApplication) {
        app.tabBars.buttons["Workouts"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Push day'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
    }

    func testEditAnImportedWorkoutAndRelaunch() {
        XCUIDevice.shared.appearance = .light
        var app = XCUIApplication()
        app.launchArguments = ["-demo-workout", "-demo-file", "-demo-reset"]
        app.launch()
        openPushDay(app)
        XCTAssertTrue(app.staticTexts["Imported from Hevy"].waitForExistence(timeout: 5))
        shot("01-read-only")
        XCTAssertFalse(app.textFields.firstMatch.exists)           // nothing editable until Edit

        app.navigationBars.buttons["Edit"].tap()
        sleep(1)
        shot("02-editing")
        // Side of the first set: Both -> Right.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Side:'")).firstMatch.tap()
        app.buttons["Right"].tap()
        // Weight of the first set: 30 -> 32.5.
        let weight = app.textFields.matching(NSPredicate(format: "label BEGINSWITH 'Weight'")).firstMatch
        weight.tap()
        weight.press(forDuration: 0.6)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        weight.typeText(XCUIKeyboardKey.delete.rawValue + "32.5")
        // Close the number pad with its own Done (the toolbar above the keys).
        let keyDone = app.toolbars.buttons["Done"].firstMatch
        if keyDone.exists { keyDone.tap() }
        sleep(1)
        if app.navigationBars.buttons["Edit"].exists { app.navigationBars.buttons["Edit"].tap() }
        // One more set of bench press.
        let add = app.buttons["Add set"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        // Rename.
        let info = app.buttons["Name, notes and times…"]
        for _ in 0..<4 where !info.isHittable { app.collectionViews.firstMatch.swipeDown() }
        info.tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.press(forDuration: 0.6)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        name.typeText(XCUIKeyboardKey.delete.rawValue + "Push day, edited")
        app.buttons["Save"].tap()
        sleep(1)
        shot("03-edited")
        app.navigationBars.buttons["Done"].tap()
        sleep(1)
        shot("04-done")

        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-demo-workout", "-demo-file"]
        app.launch()
        app.tabBars.buttons["Workouts"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Push day, edited'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("4 sets"))
        row.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '32.5 lb'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["right side"].exists)
        shot("05-after-relaunch")
    }
}
