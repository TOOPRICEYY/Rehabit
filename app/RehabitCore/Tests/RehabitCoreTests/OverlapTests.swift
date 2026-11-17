import XCTest
@testable import RehabitCore

final class OverlapTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 0)

    func at(_ text: String) -> Date { GarminClient.localTime(text + ":00", zone: zone)! }
    func model() throws -> AppModel {
        AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
    }
    func entry(_ name: String, _ m: AppModel) throws -> CatalogueExercise {
        try XCTUnwrap(m.library.catalogue.first { $0.name == name }, name)
    }

    /// The injured left side logged on the phone, the healthy side on the watch.
    func visit(_ m: AppModel) throws {
        clock = at("2026-11-10 17:00")
        m.startWorkout(title: "Rehab")
        for _ in 0..<3 {
            var s = try XCTUnwrap(m.addSet(try entry("Chest Fly (Cable)", m), side: .left))
            s.loadValue = 10; s.reps = 12
            m.update(s)
        }
        var squat = try XCTUnwrap(m.addSet(try entry("Squat (Barbell)", m)))
        squat.loadValue = 135; squat.reps = 5
        m.update(squat)
        clock = at("2026-11-10 17:40")
        m.finishWorkout()
        let watch = ImportedWorkout(sourceID: "1", title: "Strength", start: at("2026-11-10 16:55"), end: at("2026-11-10 17:45"), sets: [
            ImportedSet(exercise: "Dumbbell Fly", reps: 12, loadValue: 30),
            ImportedSet(exercise: "Dumbbell Fly", reps: 12, loadValue: 30),
            ImportedSet(exercise: "Barbell Squat", reps: 5, loadValue: 135),
            ImportedSet(exercise: "Lat Pulldown", reps: 10, loadValue: 100),
        ])
        m.importWorkouts([watch], source: GarminSource.sourceName, inferSide: false)
    }

    func testWatchSetsBesideAOneSidedLogAreProposedForTheOtherSideAndNothingChangesUnasked() throws {
        let m = try model()
        try visit(m)
        let overlaps = m.sessionOverlaps
        XCTAssertEqual(overlaps.count, 1)
        let overlap = try XCTUnwrap(overlaps.first)
        XCTAssertEqual(overlap.logged.title, "Rehab")
        XCTAssertEqual(overlap.proposals.map(\.exercise), ["Dumbbell Fly"])
        XCTAssertEqual(overlap.proposals.first?.side, .right); XCTAssertEqual(overlap.proposals.first?.loggedSide, .left)
        XCTAssertEqual(overlap.proposals.first?.setIDs.count, 2)
        // The squat is on both sides in both: maybe the same set twice. The pulldown is in one only.
        XCTAssertEqual(overlap.repeated.map(\.exercise), ["Barbell Squat"])
        // Nothing has changed yet.
        XCTAssertTrue(m.sets(of: overlap.watch).allSatisfy { $0.side == .both })

        m.accept(overlap.proposals)
        let fly = m.sets(of: overlap.watch).filter { $0.exercise == "Dumbbell Fly" }
        XCTAssertEqual(fly.map(\.side), [.right, .right])
        XCTAssertEqual(fly.map(\.sideInferred), [false, false])              // chosen, not worked out by rule
        XCTAssertEqual(m.sessionOverlaps.first?.proposals.count, 0)
        m.remove(try XCTUnwrap(m.sessionOverlaps.first?.repeated.first))
        XCTAssertTrue(m.sessionOverlaps.isEmpty)
        XCTAssertEqual(m.sets(of: overlap.watch).map(\.exercise), ["Dumbbell Fly", "Dumbbell Fly", "Lat Pulldown"])
        // Reading the watch again does not bring the removed set back.
        try visitAgain(m)
        XCTAssertEqual(m.sets(of: overlap.watch).count, 3)
        XCTAssertNil(m.lastError)
    }

    func visitAgain(_ m: AppModel) throws {
        let watch = ImportedWorkout(sourceID: "1", title: "Strength", start: at("2026-11-10 16:55"), end: at("2026-11-10 17:45"), sets: [
            ImportedSet(exercise: "Barbell Squat", reps: 5, loadValue: 135),
        ])
        m.importWorkouts([watch], source: GarminSource.sourceName, inferSide: false)
    }

    func testAKeptPairIsNotAskedAboutAgainAndFarApartSessionsAreNotAVisit() throws {
        let m = try model()
        try visit(m)
        m.keep(try XCTUnwrap(m.sessionOverlaps.first))
        XCTAssertTrue(m.sessionOverlaps.isEmpty)
        XCTAssertTrue(m.sets(of: try XCTUnwrap(m.workouts.first { $0.id.hasPrefix("garmin:") })).allSatisfy { $0.side == .both })
        // A watch session an hour after the log ended is another visit.
        let later = ImportedWorkout(sourceID: "2", title: "Strength", start: at("2026-11-10 19:00"), end: at("2026-11-10 19:30"),
                                    sets: [ImportedSet(exercise: "Dumbbell Fly", reps: 12, loadValue: 30)])
        m.importWorkouts([later], source: GarminSource.sourceName, inferSide: false)
        XCTAssertTrue(m.sessionOverlaps.isEmpty)
    }

    func testTheSpreadsheetReadsBackWithSidesHoldsAndKinds() throws {
        let m = try model()
        clock = at("2026-11-10 17:00")
        m.startWorkout(title: "Legs, \"heavy\"")
        var a = try XCTUnwrap(m.addSet(try entry("Single-Leg Extension (Machine)", m), side: .right))
        a.loadValue = 20; a.reps = 10; a.pain = 2.5; a.painType = .ache; a.notes = "slow, controlled"
        m.update(a)
        var b = try XCTUnwrap(m.addSet(try entry("Wall Sit", m)))
        b.holdSeconds = 45
        m.update(b)
        var c = try XCTUnwrap(m.addSet(try entry("Squat (Barbell)", m)))
        c.loadValue = 60; c.loadUnit = .kg; c.reps = 5; c.isWarmup = true
        m.update(c)
        clock = at("2026-11-10 17:45")
        m.finishWorkout()
        let csv = m.exportCSV()
        XCTAssertTrue(csv.hasPrefix("title,start_time,end_time,"))
        XCTAssertTrue(csv.contains("\"Legs, \"\"heavy\"\"\",\"10 Nov 2026, 17:00:00\",\"10 Nov 2026, 17:45:00\""), csv)
        let back = try HevyCSV.parse(csv, zone: zone)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].title, "Legs, \"heavy\""); XCTAssertEqual(back[0].start, at("2026-11-10 17:00"))
        XCTAssertEqual(back[0].sets.map(\.exercise), ["Single-Leg Extension (Machine)", "Wall Sit", "Squat (Barbell)"])
        XCTAssertEqual(back[0].sets[0].side, .right); XCTAssertEqual(back[0].sets[0].loadValue, 20)
        XCTAssertEqual(back[0].sets[0].pain, 2.5)
        XCTAssertEqual(back[0].sets[0].notes, "Right side. slow, controlled")
        XCTAssertEqual(back[0].sets[1].kind, .hold); XCTAssertEqual(back[0].sets[1].holdSeconds, 45)
        XCTAssertEqual(back[0].sets[2].loadUnit, .kg); XCTAssertTrue(back[0].sets[2].isWarmup)
        XCTAssertEqual(try model().exportCSV().split(separator: "\n").count, 1)   // nothing logged: the header alone
    }
}
