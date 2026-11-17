import XCTest

/// The Workouts tab: deleting from History with a confirmation and Undo, the
/// review of a visit recorded by both the watch and the phone, and the card
/// comparing this week with the usual ones, on demo data.
final class WorkoutsTabTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        executionTimeAllowance = 230
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "workouts-" + name
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ extra: [String] = [], dark: Bool = false) -> XCUIApplication {
        XCUIDevice.shared.appearance = dark ? .dark : .light
        let app = XCUIApplication()
        app.launchArguments = ["-demo-workout"] + extra
        app.launch()
        app.tabBars.buttons["Workouts"].tap()
        return app
    }

    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Scrolls the list until the element can be tapped.
    private func reveal(_ app: XCUIApplication, _ item: XCUIElement, swipes: Int = 6) {
        var left = swipes
        while (!item.exists || !item.isHittable) && left > 0 {
            app.swipeUp()
            left -= 1
        }
    }

    func testDeleteAndUndo() {
        let app = launch()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Push day'")).firstMatch
        reveal(app, row)
        XCTAssertTrue(row.isHittable)
        row.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        shot("01-swipe")
        delete.tap()
        XCTAssertTrue(app.staticTexts["Delete Push day?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["It is kept in Recently deleted for 30 days."].exists)
        shot("02-confirm")
        app.alerts.buttons["Delete"].tap()

        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Deleted Push day"].exists)
        XCTAssertFalse(row.exists)
        shot("03-undo-banner")
        undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertFalse(undo.exists)
        shot("04-restored")

        // Deleted again and left alone, the banner goes after a few seconds.
        reveal(app, row)
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: undo)
        wait(for: [gone], timeout: 10)
        shot("05-banner-gone")
    }

    private func openReview(_ app: XCUIApplication, shotName: String) {
        let card = app.buttons["overlap-card"]
        reveal(app, card)
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.label.contains("Your watch and Rehabit both recorded this visit"))
        shot(shotName)
        card.tap()
        XCTAssertTrue(app.navigationBars["Same visit"].waitForExistence(timeout: 3))
    }

    func testOverlapProposedSidesThenRemove() {
        let app = launch(["-demo-overlap"])
        openReview(app, shotName: "10-overlap-card")
        XCTAssertTrue(element(app, containing: "with no side").exists)
        XCTAssertTrue(element(app, containing: "may be the same work recorded twice").exists)
        shot("11-review")
        app.swipeUp()
        shot("12-review-actions")

        app.buttons["Use the proposed sides"].tap()
        XCTAssertTrue(app.buttons["Use the proposed sides"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Remove the repeated sets"].exists)
        shot("13-after-sides")

        app.buttons["Remove the repeated sets"].tap()
        XCTAssertTrue(app.staticTexts["Remove 2 sets from Strength?"].waitForExistence(timeout: 3))
        shot("14-remove-confirm")
        app.alerts.buttons["Remove the repeated sets"].tap()
        XCTAssertTrue(app.staticTexts["Nothing left to review."].waitForExistence(timeout: 3))
        shot("15-nothing-left")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["overlap-card"].waitForNonExistence(timeout: 3))
        shot("16-card-gone")
    }

    func testOverlapKeepBoth() {
        let app = launch(["-demo-overlap", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"],
                         dark: true)
        openReview(app, shotName: "19-overlap-card-large-dark")
        shot("20-review-large-dark")
        let keep = app.buttons["Keep both as they are"]
        reveal(app, keep)
        shot("21-review-large-dark-actions")
        keep.tap()
        XCTAssertTrue(app.staticTexts["Nothing left to review."].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["overlap-card"].waitForNonExistence(timeout: 3))
    }

    func testRecoveryCard() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["This week against your usual"].firstMatch.waitForExistence(timeout: 5)
                      || app.staticTexts["THIS WEEK AGAINST YOUR USUAL"].firstMatch.exists)
        XCTAssertTrue(element(app, containing: "Left quadriceps:").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, containing: "Steps:").waitForExistence(timeout: 10))
        shot("30-recovery")
        app.terminate()

        let dark = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"], dark: true)
        XCTAssertTrue(element(dark, containing: "Steps:").waitForExistence(timeout: 10))
        shot("31-recovery-large-dark")
    }
}
