import XCTest
@testable import RehabitCore

final class ImportTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    let header = "\"title\",\"start_time\",\"end_time\",\"description\",\"exercise_title\",\"superset_id\",\"exercise_notes\",\"set_index\",\"set_type\",\"weight_lbs\",\"reps\",\"distance_miles\",\"duration_seconds\",\"rpe\"\n"

    func model() throws -> AppModel {
        AppModel(store: try Store(path: ":memory:"), zone: zone,
                 now: { Date(timeIntervalSince1970: 1_795_000_000) })
    }

    func testCSVRowsHandleQuotesCommasAndLineBreaks() {
        let rows = HevyCSV.rows("a,\"b, c\",\"say \"\"hi\"\"\"\r\n\"two\nlines\",,x\n\n")
        XCTAssertEqual(rows, [["a", "b, c", "say \"hi\""], ["two\nlines", "", "x"]])
    }

    func testTimeIsReadInTheGivenZone() {
        let t = HevyCSV.time("23 Oct 2026, 16:58", zone: zone)!
        XCTAssertEqual(Day(t, in: zone).description, "2026-10-23")
        XCTAssertEqual(t.timeIntervalSince1970, 1_792_789_080)   // 20:58 UTC, daylight time
        XCTAssertNil(HevyCSV.time("yesterday", zone: zone))
    }

    func testParseGroupsSetsAndReadsNotes() throws {
        let csv = header + """
        "Rehab","23 Oct 2026, 16:58","23 Oct 2026, 17:09","felt ok","Bench Press (Dumbbell)",,"Left arm, 3.5/10 pain",0,"warmup",15,10,,,
        "Rehab","23 Oct 2026, 16:58","23 Oct 2026, 17:09","felt ok","Bench Press (Dumbbell)",,"",1,"normal",15,8,,,8
        "Rehab","23 Oct 2026, 16:58","23 Oct 2026, 17:09","felt ok","Leg Extension (Machine)",,"Iso hold at 45",0,"normal",10,30,,,
        "Rehab","23 Oct 2026, 16:58","23 Oct 2026, 17:09","felt ok","Plank",,"",0,"normal",,,,45,
        "Legs","24 Oct 2026, 09:00","24 Oct 2026, 09:30","","Mystery Move",,"",0,"normal",50,5,,,
        """
        let workouts = try HevyCSV.parse(csv, zone: zone)
        XCTAssertEqual(workouts.map(\.title), ["Rehab", "Legs"])
        let sets = workouts[0].sets
        XCTAssertEqual(sets.count, 4)
        XCTAssertEqual(sets[0].side, .left); XCTAssertEqual(sets[0].pain, 3.5); XCTAssertTrue(sets[0].isWarmup)
        XCTAssertNil(sets[1].side); XCTAssertEqual(sets[1].repsInReserve, 2)
        XCTAssertEqual(sets[2].kind, .hold); XCTAssertEqual(sets[2].holdSeconds, 30); XCTAssertNil(sets[2].reps)
        XCTAssertEqual(sets[3].kind, .hold); XCTAssertEqual(sets[3].holdSeconds, 45); XCTAssertNil(sets[3].loadValue)
        XCTAssertEqual(workouts[0].notes, "felt ok")
    }

    func testAFileThatIsNotAHevyExportIsRefused() {
        XCTAssertThrowsError(try HevyCSV.parse("a,b\n1,2\n", zone: zone))
        XCTAssertThrowsError(try HevyCSV.parse("", zone: zone))
        XCTAssertThrowsError(try HevyCSV.parse(header + "\"Rehab\",\"soon\",\"\",\"\",\"Plank\",,\"\",0,\"normal\",,,,45,\n", zone: zone))
    }

    func testKilogramExportsKeepTheirUnit() throws {
        let csv = "title,start_time,end_time,description,exercise_title,exercise_notes,set_index,set_type,weight_kg,reps\n"
            + "A,\"1 Jan 2026, 08:00\",\"1 Jan 2026, 08:30\",,Squat (Barbell),,0,normal,100,5\n"
        let set = try XCTUnwrap(HevyCSV.parse(csv, zone: zone).first?.sets.first)
        XCTAssertEqual(set.loadUnit, .kg); XCTAssertEqual(set.loadValue, 100)
    }

    func testMatcherFollowsTheServiceRules() {
        XCTAssertEqual(ExerciseMatcher.pattern(for: "Seated Calf Raise"), "calf_raise")
        XCTAssertEqual(ExerciseMatcher.pattern(for: "Leg Press (Machine)"), "leg_press")
        XCTAssertEqual(ExerciseMatcher.pattern(for: "Triceps Pushdown"), "triceps_extension")
        XCTAssertEqual(ExerciseMatcher.pattern(for: "Incline Bench Press (Dumbbell)"), "press_incline")
        XCTAssertNil(ExerciseMatcher.pattern(for: "Mystery Move"))
        let entry = ExerciseMatcher.entry(for: "Seated Dumbbell Press", in: .standard)
        XCTAssertEqual(entry.pattern, "press_overhead"); XCTAssertEqual(entry.entry.convention, .perHand)
        XCTAssertEqual(ExerciseMatcher.entry(for: "bench press (dumbbell)", in: .standard).entry.name, "Bench Press (Dumbbell)")
    }

    func testImportStoresOnceAndInfersTheInjuredSide() throws {
        let m = try model()
        let pec = try XCTUnwrap(Library.standard.pattern("press_horizontal")?.links.first?.tissue)
        m.save(Injury(label: "Pec", side: .left, onset: Day("2026-06-01")!, tissues: [pec]))
        let csv = header + """
        "Rehab","23 Oct 2026, 16:58","23 Oct 2026, 17:09","","Bench Press (Dumbbell)",,"",0,"normal",15,10,,,
        "Rehab","23 Oct 2026, 16:58","23 Oct 2026, 17:09","","Mystery Move",,"",1,"normal",5,10,,,
        "Old","2 Jan 2019, 10:00","2 Jan 2019, 10:40","","Bench Press (Dumbbell)",,"",0,"normal",40,8,,,
        """
        let parsed = try HevyCSV.parse(csv, zone: zone)
        let first = m.importWorkouts(parsed, source: HevyCSV.source)
        XCTAssertEqual(first.workoutsAdded, 2); XCTAssertEqual(first.setsAdded, 3)
        XCTAssertEqual(first.unmapped, ["Mystery Move"]); XCTAssertEqual(first.sidesInferred, 1)
        XCTAssertNil(m.active)
        XCTAssertEqual(m.workouts.count, 2)
        let rehab = try XCTUnwrap(m.workouts.first { $0.title == "Rehab" })
        let sets = m.sets(of: rehab)
        XCTAssertEqual(sets.first?.side, .left); XCTAssertEqual(sets.first?.convention, .perHand)
        XCTAssertEqual(sets.first?.pattern, "press_horizontal")
        // Before the injury began, the same exercise is not taken as one-sided.
        let old = try XCTUnwrap(m.workouts.first { $0.title == "Old" })
        XCTAssertEqual(m.sets(of: old).first?.side, .both)

        let again = m.importWorkouts(parsed, source: HevyCSV.source)
        XCTAssertEqual(again.workoutsAdded, 0); XCTAssertEqual(again.workoutsSkipped, 2)
        XCTAssertEqual(m.workouts.count, 2)

        // A workout deleted here does not come back with the next import.
        m.deleteWorkout(rehab)
        XCTAssertEqual(m.importWorkouts(parsed, source: HevyCSV.source).workoutsAdded, 0)
        XCTAssertEqual(m.workouts.count, 1)
        XCTAssertNil(m.lastError)
    }

    func testImportedLoadCountsInTheLedger() throws {
        let m = try model()
        let csv = header + "\"A\",\"10 Nov 2026, 10:00\",\"10 Nov 2026, 10:30\",\"\",\"Squat (Barbell)\",,\"\",0,\"normal\",135,5,,,\n"
        m.importWorkouts(try HevyCSV.parse(csv, zone: zone), source: HevyCSV.source)
        XCTAssertFalse(m.tissueWeeks().isEmpty)
    }
}
