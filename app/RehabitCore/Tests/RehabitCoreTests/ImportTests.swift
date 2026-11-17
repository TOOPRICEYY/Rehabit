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

    func testSidesAreWorkedOutAgainWhenAnInjuryIsEnteredAfterTheImport() throws {
        let m = try model()
        let csv = header + """
        "Rehab","23 Oct 2026, 16:58","23 Oct 2026, 17:09","","Bench Press (Dumbbell)",,"",0,"normal",15,10,,,
        "Rehab","23 Oct 2026, 16:58","23 Oct 2026, 17:09","","Triceps Pushdown",,"Right arm",1,"normal",12.5,10,,,
        "Rehab","23 Oct 2026, 16:58","23 Oct 2026, 17:09","","Squat (Barbell)",,"",2,"normal",95,5,,,
        "Old","2 Jan 2019, 10:00","2 Jan 2019, 10:40","","Bench Press (Dumbbell)",,"",0,"normal",40,8,,,
        """
        m.importWorkouts(try HevyCSV.parse(csv, zone: zone), source: HevyCSV.source)
        func sides(_ title: String) -> [Side] { m.sets(of: m.workouts.first { $0.title == title }!).map(\.side) }
        XCTAssertEqual(sides("Rehab"), [.both, .right, .both])     // no injury known yet

        let pec = try XCTUnwrap(Library.standard.pattern("press_horizontal")?.links.first?.tissue)
        var injury = Injury(label: "Pec", side: .left, onset: Day("2026-06-01")!, tissues: [pec])
        m.save(injury)
        XCTAssertEqual(sides("Rehab"), [.left, .right, .both])     // the note's side is kept
        XCTAssertEqual(sides("Old"), [.both])                      // before the injury began
        XCTAssertEqual(m.reapplyImportedSides(), 0)                // nothing left to change

        // A workout logged in the app is never touched.
        m.startWorkout(title: "Mine")
        _ = m.addSet(Library.standard.catalogue.first { $0.name == "Bench Press (Dumbbell)" }!, side: .both)
        _ = m.finishWorkout()
        m.save(injury)
        XCTAssertEqual(sides("Mine"), [.both])

        injury.resolvedOn = Day("2026-08-01")                      // resolved before the session
        m.save(injury)
        XCTAssertEqual(sides("Rehab"), [.both, .right, .both])
        m.deleteInjury(id: injury.id)
        XCTAssertEqual(sides("Rehab"), [.both, .right, .both])
        XCTAssertNil(m.lastError)
    }

    func testImportedLoadCountsInTheLedger() throws {
        let m = try model()
        let csv = header + "\"A\",\"10 Nov 2026, 10:00\",\"10 Nov 2026, 10:30\",\"\",\"Squat (Barbell)\",,\"\",0,\"normal\",135,5,,,\n"
        m.importWorkouts(try HevyCSV.parse(csv, zone: zone), source: HevyCSV.source)
        XCTAssertFalse(m.tissueWeeks().isEmpty)
    }

    func testASetGoesToTheInjuryItsExerciseWorksHardest() throws {
        let m = try model()
        // An older injury on the left chest and a newer one in the right triceps.
        m.save(Injury(label: "Chest", side: .left, onset: Day("2025-11-04")!, tissues: ["pec_major"]))
        m.save(Injury(label: "Triceps", side: .right, onset: Day("2026-07-15")!, onsetPrecision: .month,
                      tissues: ["triceps"]))
        m.save(Injury(label: "Thigh", side: .right, onset: Day("2026-05-03")!, tissues: ["quads"]))
        let csv = header + """
        "Rehab","23 Oct 2026, 16:58","23 Oct 2026, 17:09","","Bench Press (Dumbbell)",,"",0,"normal",15,10,,,
        "Rehab","23 Oct 2026, 16:58","23 Oct 2026, 17:09","","Triceps Pushdown",,"",1,"normal",12.5,10,,,
        "Rehab","23 Oct 2026, 16:58","23 Oct 2026, 17:09","","Squat (Bodyweight)",,"",2,"normal",,10,,,
        "Rehab","23 Oct 2026, 16:58","23 Oct 2026, 17:09","","Push-Up",,"",3,"normal",,10,,,
        "Rehab","23 Oct 2026, 16:58","23 Oct 2026, 17:09","","Bicep Curl (Dumbbell)",,"",4,"normal",10,10,,,
        "Rehab","23 Oct 2026, 16:58","23 Oct 2026, 17:09","","Bench Press (Dumbbell)",,"Right arm",5,"normal",25,10,,,
        "Early","3 Jul 2026, 10:00","3 Jul 2026, 10:20","","Triceps Pushdown",,"",0,"normal",12.5,10,,,
        "Before","20 Jun 2026, 10:00","20 Jun 2026, 10:20","","Triceps Pushdown",,"",0,"normal",12.5,10,,,
        """
        m.importWorkouts(try HevyCSV.parse(csv, zone: zone), source: HevyCSV.source)
        func sets(_ title: String) -> [WorkoutSet] { m.sets(of: m.workouts.first { $0.title == title }!) }
        // The press works the chest harder than the triceps, so the chest injury decides it,
        // though the triceps injury is the newer. Body weight is moved by both sides. A curl
        // works neither injury hard enough. A side given in a note is logged, not inferred.
        XCTAssertEqual(sets("Rehab").map(\.side), [.left, .right, .both, .both, .both, .right])
        XCTAssertEqual(sets("Rehab").map(\.sideInferred), [true, true, nil, nil, nil, nil])
        // An injury dated only to July may have begun on the first of July, and not in June.
        XCTAssertEqual(sets("Early").map(\.side), [.right])
        XCTAssertEqual(sets("Before").map(\.side), [.both])

        // The side offered for a one-sided exercise follows the same rule.
        let press = try XCTUnwrap(Library.standard.catalogue.first { $0.pattern == "press_horizontal" && $0.unilateral })
        XCTAssertEqual(m.likelySide(for: press), .left)
        XCTAssertNil(m.lastError)
    }

    func testRecordsPreparedElsewhereAreListedThenTakenIn() throws {
        let m = try model()
        let csv = header + "\"Rehab\",\"23 Oct 2026, 16:58\",\"23 Oct 2026, 17:09\",\"\",\"Bench Press (Dumbbell)\",,\"\",0,\"normal\",15,10,,,\n"
        m.importWorkouts(try HevyCSV.parse(csv, zone: zone), source: HevyCSV.source)
        let rehab = try XCTUnwrap(m.workouts.first)
        XCTAssertEqual(m.sets(of: rehab).map(\.side), [.both])

        // A file holding injuries and nothing else, with a deletion that must be ignored.
        let file = Data("""
        {"schemaVersion": 1,
         "injuries": [
          {"id": "chest-left", "label": "Left chest strain", "side": "left", "onset": "2025-11-04",
           "onsetPrecision": "day", "tissues": ["pec_major"], "mechanism": "Rows", "notes": "",
           "updatedAt": "2026-11-17T17:00:00.000Z"},
          {"id": "thigh-right", "label": "Right thigh strain", "side": "right", "onset": "2026-05-03",
           "onsetPrecision": "week", "tissues": ["quads"], "mechanism": "", "notes": "",
           "updatedAt": "2026-11-17T17:00:00.000Z"}],
         "tombstones": [{"kind": "workout", "id": "\(rehab.id)", "deletedAt": "2030-01-01T00:00:00.000Z"}],
         "profile": {"bodyweightKg": 40, "unit": "kg"}, "profileUpdatedAt": "2030-01-01T00:00:00.000Z"}
        """.utf8)
        let waiting = try m.incoming(file)
        XCTAssertEqual(waiting.injuries.map(\.label), ["Left chest strain", "Right thigh strain"])
        XCTAssertEqual(waiting.count, 2)
        XCTAssertTrue(m.injuries.isEmpty)                         // looking stores nothing

        let unit = m.profile.unit
        XCTAssertEqual(m.takeIn(file), 2)
        XCTAssertEqual(m.injuries.map(\.id).sorted(), ["chest-left", "thigh-right"])
        XCTAssertEqual(m.workouts.count, 1)                       // the deletion in the file was ignored
        XCTAssertEqual(m.profile.unit, unit)                      // and so was its profile
        XCTAssertEqual(m.sets(of: rehab).map(\.side), [.left])    // the imported log now reads as the left side
        XCTAssertEqual(m.sets(of: rehab).map(\.sideInferred), [true])
        XCTAssertTrue(try m.incoming(file).isEmpty)               // nothing left to take in
        XCTAssertEqual(m.takeIn(file), 0)

        // An injury deleted on the phone does not come back from the same file.
        m.deleteInjury(id: "thigh-right")
        XCTAssertTrue(try m.incoming(file).isEmpty)
        XCTAssertEqual(m.takeIn(file), 0)
        XCTAssertEqual(m.injuries.map(\.id), ["chest-left"])
        // One changed on the phone keeps the phone's version.
        var chest = try XCTUnwrap(m.injuries.first)
        chest.label = "Left pec"
        m.save(chest)
        XCTAssertEqual(m.takeIn(file), 0)
        XCTAssertEqual(m.injuries.first?.label, "Left pec")
        XCTAssertNil(m.lastError)

        XCTAssertThrowsError(try m.incoming(Data("not json".utf8)))
        XCTAssertThrowsError(try m.incoming(Data("{\"schemaVersion\": 99}".utf8)))
    }
}
