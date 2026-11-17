import XCTest
@testable import RehabitCore

final class BodyMapTests: XCTestCase {
    func testEveryTissueIsDrawnAndNoRegionIsUnknown() {
        let library = Library.standard
        let drawn = Set(BodyMap.regions.map(\.tissue))
        XCTAssertEqual(drawn, Set(library.tissues.map(\.id)))
        for region in BodyMap.regions { XCTAssertNotNil(library.tissue(region.tissue), region.tissue) }
        // Tendons are the distinct small shapes.
        let tendons = Set(library.tissues.filter { $0.kind == "tendon" }.map(\.id))
        XCTAssertEqual(Set(BodyMap.regions.filter(\.isTendon).map(\.tissue)), tendons)
        XCTAssertEqual(Set(BodyMap.regions(.front).map(\.tissue)).intersection(BodyMap.regions(.back).map(\.tissue)),
                       ["side_delt", "forearm"])
    }

    func testRegionsStayOnTheirHalfAndInsideTheFigure() {
        for region in BodyMap.regions {
            let s = region.shape
            XCTAssertLessThanOrEqual(s.x, BodyMap.size.width / 2, region.tissue)     // the viewer's left half
            XCTAssertGreaterThan(s.x - s.width / 2, 0, region.tissue)
            XCTAssertLessThan(s.y + s.height / 2, BodyMap.size.height, region.tissue)
            XCTAssertEqual(s.mirrored.mirrored, s)
            XCTAssertEqual(s.mirrored.x, BodyMap.size.width - s.x)
        }
    }

    /// The worst bug this screen could have is a side drawn on the wrong half.
    func testSidesFaceTheRightWay() {
        // Facing the person: their right arm is on the viewer's left.
        XCTAssertEqual(BodyView.front.side(onViewerLeft: true), .right)
        XCTAssertEqual(BodyView.front.side(onViewerLeft: false), .left)
        // From behind: their left is on the viewer's left.
        XCTAssertEqual(BodyView.back.side(onViewerLeft: true), .left)
        XCTAssertEqual(BodyView.back.side(onViewerLeft: false), .right)
        XCTAssertFalse(BodyView.front.isOnViewerLeft(.left))
        XCTAssertTrue(BodyView.back.isOnViewerLeft(.left))
    }

    private func week(_ week: Double, usual: Double) -> TissueWeek {
        TissueWeek(tissue: Library.standard.tissue("quads")!, side: .left, week: week, usualWeek: usual)
    }

    func testHeatLevels() {
        // No load is empty in both readings, never the lowest colour.
        XCTAssertEqual(HeatLevel(nil, reading: .thisWeek, maxWeek: 100), .empty)
        XCTAssertEqual(HeatLevel(week(0, usual: 40), reading: .versusUsual, maxWeek: 100), .empty)
        // This week: against the most-loaded tissue.
        XCTAssertEqual(HeatLevel(week(25, usual: 0), reading: .thisWeek, maxWeek: 100), .value(0.25))
        XCTAssertEqual(HeatLevel(week(100, usual: 0), reading: .thisWeek, maxWeek: 100), .value(1))
        // Versus usual: a new tissue has no ratio and is marked, not coloured.
        XCTAssertEqual(HeatLevel(week(25, usual: 0), reading: .versusUsual, maxWeek: 100), .new)
        XCTAssertEqual(HeatLevel(week(40, usual: 40), reading: .versusUsual, maxWeek: 100), .value(0))
        XCTAssertEqual(HeatLevel(week(80, usual: 40), reading: .versusUsual, maxWeek: 100), .value(1))
        XCTAssertEqual(HeatLevel(week(20, usual: 40), reading: .versusUsual, maxWeek: 100), .value(-1))
        // Clamped beyond half and double.
        XCTAssertEqual(HeatLevel(week(400, usual: 40), reading: .versusUsual, maxWeek: 400), .value(1))
        XCTAssertEqual(HeatLevel(week(2, usual: 40), reading: .versusUsual, maxWeek: 100), .value(-1))
        XCTAssertEqual(HeatLevel.position(ofRatio: 1.5), log2(1.5), accuracy: 1e-12)
    }
}

final class LoadDetailTests: XCTestCase {
    var clock = Date(timeIntervalSince1970: 1_763_300_000)

    func testContributionsWeeklyBarsAndSteppingBack() throws {
        let model = AppModel(store: try Store(path: ":memory:"), zone: TimeZone(identifier: "America/Detroit")!,
                             now: { [unowned self] in self.clock })
        func entry(_ name: String) -> CatalogueExercise { model.library.catalogue.first { $0.name == name }! }
        func session(_ items: [(String, Side, Double)]) {
            model.startWorkout()
            for (name, side, reps) in items {
                var s = model.addSet(entry(name), side: side)!
                s.reps = reps; s.loadValue = 50
                model.update(s)
            }
            model.finishWorkout()
        }
        // Three weeks ago: squats only. This week: squats, and leg extensions on the left.
        session([("Squat (Barbell)", .both, 10)])
        clock.addTimeInterval(21 * 86_400)
        session([("Squat (Barbell)", .both, 10), ("Single-Leg Extension (Machine)", .left, 12)])

        let left = model.tissueDetail("quads", side: .left)
        let right = model.tissueDetail("quads", side: .right)
        XCTAssertEqual(left.weekly.count, 5)
        XCTAssertGreaterThan(left.week, right.week)                  // the extension was left only
        XCTAssertEqual(left.contributions.map(\.exercise).sorted(),
                       ["Single-Leg Extension (Machine)", "Squat (Barbell)"])
        XCTAssertEqual(right.contributions.map(\.exercise), ["Squat (Barbell)"])
        XCTAssertEqual(left.contributions.map(\.dose).reduce(0, +), left.week, accuracy: 1e-9)
        // A set with both sides counts in full on each side.
        let squatLeft = left.contributions.first { $0.exercise == "Squat (Barbell)" }!.dose
        XCTAssertEqual(squatLeft, right.week, accuracy: 1e-9)
        XCTAssertEqual(left.weekly[1], right.weekly[1], accuracy: 1e-9)   // three weeks back, squats only
        XCTAssertGreaterThan(left.weekly[1], 0)

        // The week view and the detail agree, and stepping back a week moves both.
        let weeks = model.tissueWeeks()
        XCTAssertEqual(weeks.first { $0.tissue.id == "quads" && $0.side == .left }?.week ?? -1, left.week, accuracy: 1e-9)
        XCTAssertEqual(left.usualWeek, weeks.first { $0.tissue.id == "quads" && $0.side == .left }!.usualWeek, accuracy: 1e-9)
        let lastWeek = model.tissueWeeks(weeksAgo: 1)
        XCTAssertEqual(lastWeek.first { $0.tissue.id == "quads" && $0.side == .left }?.week ?? 0, 0)
        let threeBack = model.tissueDetail("quads", side: .left, weeksAgo: 3)
        XCTAssertGreaterThan(threeBack.week, 0)
        XCTAssertEqual(threeBack.contributions.map(\.exercise), ["Squat (Barbell)"])
        XCTAssertEqual(model.injuredTissueSides, [:])
    }
}
