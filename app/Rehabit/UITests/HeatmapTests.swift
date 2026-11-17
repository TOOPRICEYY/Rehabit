import XCTest

/// The Load tab's body map with the demo data; keeps a screenshot of each state.
final class HeatmapTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        executionTimeAllowance = 120
    }

    private func open(_ extra: [String] = ["-demo-workout"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = extra
        app.launch()
        app.tabBars.buttons["Load"].tap()
        let body = app.segmentedControls.buttons["Body"]
        if body.waitForExistence(timeout: 5) { body.tap() }
        sleep(1)
        return app
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "heatmap-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    private func walk(_ tag: String) {
        let app = open()
        app.segmentedControls.buttons["Versus usual"].tap()
        shot("\(tag)-01-versus-usual")
        app.swipeUp()
        sleep(1)
        shot("\(tag)-02-legend")
        app.swipeDown()
        app.segmentedControls.buttons["This week"].tap()
        sleep(1)
        shot("\(tag)-03-this-week")
        app.segmentedControls.buttons["Versus usual"].tap()
        let quad = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Left quadriceps'")).firstMatch
        if quad.waitForExistence(timeout: 3) { quad.tap() }
        sleep(1)
        shot("\(tag)-04-detail-left-quads")
        app.swipeUp()
        sleep(1)
        shot("\(tag)-05-detail-large")
    }

    func testLight() {
        XCUIDevice.shared.appearance = .light
        walk("light")
    }

    func testDark() {
        XCUIDevice.shared.appearance = .dark
        walk("dark")
        XCUIDevice.shared.appearance = .light
    }

    func testStepBackAndLargestText() {
        XCUIDevice.shared.appearance = .light
        let app = open()
        app.buttons["Earlier week"].tap()
        sleep(1)
        shot("week-back")
        app.terminate()
        let big = open(["-demo-workout", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        shot("xxxl-01")
        big.swipeUp()
        sleep(1)
        shot("xxxl-02")
    }

    func testEmpty() {
        XCUIDevice.shared.appearance = .light
        _ = open(["-demo-empty"])
        shot("empty")
    }
}
