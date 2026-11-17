import XCTest

/// Walks the workout screen with the demo data and keeps a screenshot of each
/// state. Export them with `xcrun xcresulttool export attachments`.
final class WorkoutScreenTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        executionTimeAllowance = 120
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout"] + extra
        app.launch()
        app.buttons["Resume workout"].tap()
        XCTAssertTrue(app.staticTexts["Goblet Squat (Dumbbell)"].waitForExistence(timeout: 5))
        return app
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func closeMenu(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.35)).tap()
        sleep(1)
    }

    private func walk(_ app: XCUIApplication, _ tag: String) {
        shot("\(tag)-01-top")
        // The card menu from the triple-dot button.
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Options for Single-Leg Extension (Machine)'")).firstMatch.tap()
        sleep(1)
        shot("\(tag)-02-card-menu")
        closeMenu(app)
        app.swipeUp(velocity: .slow)
        sleep(1)
        shot("\(tag)-03a-each-side")
        // The set menu from the set badge of the each-side exercise.
        let badges = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Set 2, options'"))
        if badges.count > 1 { badges.element(boundBy: 1).tap() } else if badges.count == 1 { badges.firstMatch.tap() }
        sleep(1)
        shot("\(tag)-03-set-menu")
        closeMenu(app)
        // The pain picker.
        let chip = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Set 1, left, pain'")).firstMatch
        if chip.exists {
            chip.tap()
            sleep(1)
            shot("\(tag)-04-pain")
            closeMenu(app)
        }
        app.swipeUp()
        sleep(1)
        shot("\(tag)-05-scrolled")
    }

    func testLight() {
        XCUIDevice.shared.appearance = .light
        walk(launch(), "light")
    }

    func testDark() {
        XCUIDevice.shared.appearance = .dark
        walk(launch(), "dark")
        XCUIDevice.shared.appearance = .light
    }

    func testLargestText() {
        XCUIDevice.shared.appearance = .light
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        shot("xxxl-01-top")
        let list = app.collectionViews.firstMatch
        list.swipeUp()
        sleep(1)
        shot("xxxl-02-scrolled")
        list.swipeUp()
        sleep(1)
        shot("xxxl-03-scrolled")
    }

    /// Switching an exercise between together and each side, and the merge question.
    func testSideSwitch() {
        let app = launch()
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Sides: Together'")).firstMatch.tap()
        sleep(1)
        shot("switch-01-squat-each-side")
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Sides: Each side'")).firstMatch.tap()
        sleep(1)
        shot("switch-02-back-together")
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Sides: Each side'")).firstMatch.tap()
        sleep(1)
        shot("switch-03-merge-question")
    }
}
