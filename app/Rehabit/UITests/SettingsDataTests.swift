import XCTest

/// Settings on demo data: saving a body weight and seeing it on the chart,
/// recently deleted workouts, and the spreadsheet export.
final class SettingsDataTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        executionTimeAllowance = 240
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "settings-" + name
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

    /// Swipes the screen up until the element can be tapped, a few times at most.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        var tries = 0
        while !(element.exists && element.isHittable) && tries < 8 {
            app.swipeUp()
            tries += 1
        }
    }

    func testBodyweightIsSavedAndCharted() {
        let app = launch()
        app.tabBars.buttons["Settings"].tap()
        let field = app.textFields["Body weight in pounds"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        shot("01-before")
        field.tap()
        field.typeText("170")
        app.buttons["Save body weight for today"].tap()
        XCTAssertTrue(app.staticTexts["Saved 170 lb for today."].waitForExistence(timeout: 3))
        let chart = app.otherElements["Body weight chart, last 90 days"].firstMatch
        let anyChart = chart.exists ? chart : app.descendants(matching: .any)["Body weight chart, last 90 days"].firstMatch
        XCTAssertTrue(anyChart.waitForExistence(timeout: 3))
        XCTAssertTrue(String(describing: anyChart.value ?? "").contains("170 lb"), "chart says \(String(describing: anyChart.value))")
        sleep(1)
        shot("02-saved-and-charted")

        // The same weight in kilograms when the unit changes.
        app.buttons["Unit, lb"].firstMatch.tap()
        let kg = app.buttons["kg"].firstMatch
        if kg.waitForExistence(timeout: 2) { kg.tap() }
        sleep(1)
        shot("03-in-kg")
    }

    func testRecentlyDeletedAndRestore() {
        let app = launch()
        // Delete one workout if the history offers it; the screen is checked either way.
        app.tabBars.buttons["Workouts"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS ' sets'")).firstMatch
        if row.waitForExistence(timeout: 3) {
            reveal(row, in: app)
            row.swipeLeft()
            let delete = app.buttons["Delete"].firstMatch
            if delete.waitForExistence(timeout: 2) { delete.tap() }
        }
        sleep(1)

        // A swipe left open takes the first tap to close; tap again if needed.
        app.tabBars.buttons["Settings"].tap()
        if !app.navigationBars["Settings"].waitForExistence(timeout: 2) { app.tabBars.buttons["Settings"].tap() }
        let link = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Recently deleted'")).firstMatch
        reveal(link, in: app)
        XCTAssertTrue(link.exists)
        shot("10-your-data")
        link.tap()
        XCTAssertTrue(app.navigationBars["Recently deleted"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Deleted workouts are kept for 30 days. A restored workout comes back with its sets, finished."].exists)
        sleep(1)
        shot("11-recently-deleted")
        let restore = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Restore '")).firstMatch
        if restore.exists {
            restore.tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'is back in your workouts.'")).firstMatch
                .waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts["Nothing deleted"].waitForExistence(timeout: 3))
            sleep(1)
            shot("12-restored")
        }
    }

    func testExportSpreadsheet() {
        let app = launch()
        app.tabBars.buttons["Settings"].tap()
        let export = app.buttons["Export spreadsheet"]
        reveal(export, in: app)
        XCTAssertTrue(export.exists)
        export.tap()
        let share = app.buttons["Share rehabit-export.csv"]
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        reveal(share, in: app)
        sleep(1)
        shot("20-export-ready")
        share.tap()
        // The system share sheet, with the file's name or its actions.
        let sheet = app.otherElements["ActivityListView"].firstMatch
        let copy = app.buttons.matching(NSPredicate(format: "label IN {'Copy', 'Save to Files'}")).firstMatch
        let shown = sheet.waitForExistence(timeout: 10) || copy.waitForExistence(timeout: 5)
        sleep(2)
        shot("21-share-sheet")
        XCTAssertTrue(shown, "the share sheet did not appear")
    }

    func testDarkModeAndLargeText() {
        let app = XCUIApplication()
        XCUIDevice.shared.appearance = .dark
        app.launchArguments = ["-demo-workout", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        app.launch()
        XCUIDevice.shared.appearance = .dark
        sleep(2)
        app.tabBars.buttons["Settings"].tap()
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("171")
            app.buttons["Save body weight for today"].tap()
        }
        sleep(1)
        shot("30-dark-large")
        let link = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Recently deleted'")).firstMatch
        reveal(link, in: app)
        app.swipeUp()
        sleep(1)
        shot("31-dark-large-your-data")
        XCUIDevice.shared.appearance = .light
    }
}
