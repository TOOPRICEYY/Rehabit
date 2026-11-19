import XCTest

/// A run from the watch: listed with its distance and time, opened with its
/// totals, and with nothing offered that needs sets.
final class ActivityTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        executionTimeAllowance = 200
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "activity-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    func testARunFromTheWatch() {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout", "-demo-activity"]
        app.launch()
        app.tabBars.buttons["Workouts"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Morning Run'")).firstMatch
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Running"), row.label)
        XCTAssertTrue(row.label.contains("31 min"), row.label)
        shot("01-list")
        row.tap()
        XCTAssertTrue(app.staticTexts["Distance"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Heart rate"].exists)
        XCTAssertTrue(app.staticTexts["Pace"].exists)
        let load = app.descendants(matching: .any)["activity-load"]
        for _ in 0..<3 where !(load.exists && load.isHittable) { app.swipeUp() }
        XCTAssertTrue(load.exists, "the run's load is shown")
        XCTAssertTrue(load.label.hasPrefix("Counts as load: about"), load.label)
        XCTAssertFalse(app.buttons["More"].exists, "no repeat or routine for a session without sets")
        shot("02-detail")
        app.navigationBars.buttons["Edit"].tap()
        XCTAssertFalse(app.buttons["Add exercise"].exists)
        shot("03-edit")
    }

    /// Garmin's "Cardio" counts for nothing until the person says what it was;
    /// choosing the bike for all of them puts them into load.
    func testCardioCountedAsTheBike() {
        XCUIDevice.shared.appearance = .light
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout", "-demo-activity"]
        app.launch()
        app.tabBars.buttons["Workouts"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Cardio'")).firstMatch
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let line = app.descendants(matching: .any)["activity-load"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertTrue(line.label.hasPrefix("Not counted as load"), line.label)
        shot("10-cardio-unknown")
        let menu = app.descendants(matching: .any)["activity-counts-as"]
        for _ in 0..<3 where !(menu.exists && menu.isHittable) { app.swipeUp() }
        menu.tap()
        let cycling = app.buttons["Cycling"].firstMatch
        XCTAssertTrue(cycling.waitForExistence(timeout: 3))
        shot("11-counts-as-menu")
        cycling.tap()
        let all = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All 2'")).firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 3), "offers every Cardio session")
        all.tap()
        XCTAssertTrue(line.label.hasPrefix("Counts as load: about"), line.label)
        shot("12-cardio-as-bike")
    }
}
