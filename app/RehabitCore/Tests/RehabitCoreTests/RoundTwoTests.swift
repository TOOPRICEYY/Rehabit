import XCTest
@testable import RehabitCore

/// What the first round of testing asked for.
final class RoundTwoTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 1_790_000_000)

    func model() throws -> AppModel {
        AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
    }

    func entry(_ name: String, _ m: AppModel) throws -> CatalogueExercise {
        try XCTUnwrap(m.library.catalogue.first { $0.name == name }, name)
    }

    func fresh(_ m: AppModel, _ set: WorkoutSet) -> WorkoutSet { m.activeSets.first { $0.id == set.id } ?? set }

    @discardableResult
    func fill(_ m: AppModel, _ set: WorkoutSet, load: Double?, reps: Double? = 10) -> WorkoutSet {
        var s = fresh(m, set)
        s.loadValue = load; s.reps = reps
        m.update(s)
        return s
    }

    func testRestStartsWhenBothSidesOfARoundAreDone() throws {
        let m = try model()
        m.startWorkout()
        let curl = try entry("Biceps Curl (Cable)", m)
        let first = m.addRound(curl, sides: [.left, .right]).map { fill(m, $0, load: 20) }
        let second = m.addRound(curl, sides: [.left, .right]).map { fill(m, $0, load: 20) }
        XCTAssertTrue(m.setDone(true, first[0]))
        XCTAssertNil(m.rest, "the rest ran with the right side of the round still to do")
        clock.addTimeInterval(40)
        XCTAssertTrue(m.setDone(true, first[1]))
        XCTAssertEqual(m.rest?.setID, first[1].id)
        XCTAssertEqual(m.rest?.startedAt, clock)

        // Someone who does every left set first: seen from the round before, so the rest runs.
        let n = try model()
        n.startWorkout()
        let a = n.addRound(curl, sides: [.left, .right]).map { fill(n, $0, load: 20) }
        let b = n.addRound(curl, sides: [.left, .right]).map { fill(n, $0, load: 20) }
        n.setDone(true, a[0])
        XCTAssertNil(n.rest)
        clock.addTimeInterval(90)
        n.setDone(true, b[0])
        XCTAssertEqual(n.rest?.setID, b[0].id)
        _ = second
    }

    func testAdjustingTheRestChangesThisCountdownOnly() throws {
        let m = try model()
        m.startWorkout()
        let bench = try entry("Bench Press (Barbell)", m)
        let one = fill(m, try XCTUnwrap(m.addSet(bench)), load: 100)
        let two = fill(m, try XCTUnwrap(m.addSet(bench)), load: 100)
        m.setDone(true, one)
        XCTAssertEqual(m.rest?.seconds, 120)
        m.adjustRest(by: 15); m.adjustRest(by: 15)
        XCTAssertEqual(m.rest?.seconds, 150)
        XCTAssertEqual(m.restSeconds(for: bench.name), 120)             // the exercise's own rest is untouched
        m.adjustRest(by: -200)                                          // taken below nothing: the rest is over
        XCTAssertNil(m.rest)
        clock.addTimeInterval(60)
        m.setDone(true, two)
        XCTAssertEqual(m.rest?.seconds, 120)                            // the next rest is the usual one
    }

    func testASetWithNoRepsIsNotMarkedDoneAndADropSetFollowsWithoutRest() throws {
        let m = try model()
        m.startWorkout()
        let bench = try entry("Bench Press (Barbell)", m)
        let empty = try XCTUnwrap(m.addSet(bench))
        XCTAssertFalse(m.setDone(true, empty))
        XCTAssertFalse(fresh(m, empty).isDone)
        let top = fill(m, empty, load: 100)
        let drop = fill(m, try XCTUnwrap(m.addSet(bench)), load: 70)
        XCTAssertNil(drop.tag)
        // Working set, warm-up, drop set, to failure, and round again.
        m.cycleKind(drop); XCTAssertTrue(fresh(m, drop).isWarmup)
        m.cycleKind(drop); XCTAssertEqual(fresh(m, drop).tag, .drop); XCTAssertFalse(fresh(m, drop).isWarmup)
        XCTAssertTrue(m.setDone(true, top))
        XCTAssertNil(m.rest, "a rest ran before the drop set")
        clock.addTimeInterval(20)
        m.setDone(true, drop)
        XCTAssertEqual(m.rest?.setID, drop.id)
        m.cycleKind(drop); XCTAssertEqual(fresh(m, drop).tag, .failure)
        m.cycleKind(drop); XCTAssertNil(fresh(m, drop).tag)
        // A set added after a tagged one is an ordinary set.
        m.cycleKind(drop); m.cycleKind(drop)
        XCTAssertNil(try XCTUnwrap(m.addSet(bench)).tag)
        // The tag is kept through an export and back.
        let other = try model()
        m.finishWorkout()
        _ = other.merge(try XCTUnwrap(m.exportJSON()))
        XCTAssertEqual(other.sets(of: other.workouts[0]).map(\.tag), [nil, .drop, nil])
    }

    func testOneStepUpIsNotRemarkedOnAndAJumpNamesItsSideAndSet() throws {
        let m = try model()
        // Four sessions at 30, 35, 40, 40 lb: the step is 5.
        for (i, load) in [30.0, 35, 40, 40].enumerated() {
            clock = Date(timeIntervalSince1970: 1_790_000_000 + Double(i) * 86_400 * 2)
            m.startWorkout()
            let curl = try entry("Biceps Curl (Cable)", m)
            for set in m.addRound(curl, sides: [.left, .right]) { fill(m, set, load: load) }
            m.finishWorkout()
        }
        clock.addTimeInterval(2 * 86_400)
        m.startWorkout()
        let curl = try entry("Biceps Curl (Cable)", m)
        XCTAssertEqual(m.loadStep(for: curl.name, unit: .lb), 5)
        let one = m.addRound(curl, sides: [.left, .right])
        let two = m.addRound(curl, sides: [.left, .right])
        m.setLinked(false, for: curl.name)
        fill(m, one[0], load: 45); fill(m, one[1], load: 40)              // 12.5 percent up, one step
        fill(m, two[0], load: 45); fill(m, two[1], load: 55)              // the right: 37.5 percent, three steps
        let jumps = m.advice(for: m.block(curl.name)).filter { $0.kind == .intensityJump }
        XCTAssertEqual(jumps.map(\.detail), ["Right, set 2: 38 percent above the heaviest in the last 28 days"])
        // One step that is a large share of a light load is still said.
        fill(m, two[1], load: 40)
        let light = try entry("Lateral Raise (Cable)", m)
        m.finishWorkout()
        for (i, load) in [5.0, 10, 15].enumerated() {
            clock.addTimeInterval(86_400)
            m.startWorkout()
            fill(m, try XCTUnwrap(m.addSet(light, side: .left)), load: i == 2 ? 10 : load)
            m.finishWorkout()
        }
        clock.addTimeInterval(86_400)
        m.startWorkout()
        fill(m, try XCTUnwrap(m.addSet(light, side: .left)), load: 15)
        XCTAssertEqual(m.advice(for: m.block(light.name)).filter { $0.kind == .intensityJump }.map(\.detail),
                       ["Left, set 1: 50 percent above the heaviest in the last 28 days"])
    }

    func testPlatesForABar() {
        XCTAssertEqual(Plates.load(total: 225, unit: .lb).perSide, [45, 45])
        XCTAssertEqual(Plates.load(total: 185, unit: .lb).perSide, [45, 25])
        XCTAssertEqual(Plates.load(total: 100, unit: .kg).perSide, [25, 15])
        let odd = Plates.load(total: 138, unit: .lb)                       // 46.5 a side: 45 and nothing for 1.5
        XCTAssertEqual(odd.perSide, [45]); XCTAssertEqual(odd.total, 135); XCTAssertEqual(odd.short, 3)
        XCTAssertEqual(Plates.load(total: 45, unit: .lb).perSide, [])
        XCTAssertEqual(Plates.load(total: 30, unit: .lb).short, -15)       // lighter than the bar itself
        XCTAssertEqual(Plates.load(total: 95, bar: 35, plates: [25, 10, 5]).perSide, [25, 5])
        XCTAssertEqual(Plates.load(total: .nan, unit: .lb).perSide, [])
    }

    func testAnInjurysNameSuggestsItsSideAndTissues() {
        let library = Library.standard
        func suggest(_ name: String) -> (Side?, [String]) {
            let s = library.suggestInjury(named: name)
            return (s.side, s.tissues)
        }
        XCTAssertEqual(suggest("Left pec strain").0, .left); XCTAssertEqual(suggest("Left pec strain").1, ["pec_major"])
        XCTAssertEqual(suggest("R knee pain").0, .right); XCTAssertEqual(suggest("R knee pain").1, ["patellar_tendon", "quads"])
        XCTAssertNil(suggest("Achilles tendinopathy").0); XCTAssertEqual(suggest("Achilles tendinopathy").1, ["achilles"])
        XCTAssertEqual(suggest("Bilateral hamstring tightness").0, .both)
        XCTAssertEqual(suggest("Upper back spasm").1, ["mid_back"])
        XCTAssertEqual(suggest("Lower back").1, ["erectors"])
        XCTAssertEqual(suggest("Right hip flexor").1, ["hip_flexors"])
        XCTAssertEqual(suggest("Tennis elbow (left)").1, ["forearm"])
        XCTAssertEqual(suggest("Something odd").1, [])
        XCTAssertNil(suggest("Flat feet").0)                              // no "l" inside a word is a side
    }

    func testMovingAnExerciseToAPlaceAndRepeatingAWorkout() throws {
        let m = try model()
        m.startWorkout(title: "Push day")
        let names = ["Bench Press (Barbell)", "Chest Fly (Cable)", "Triceps Pushdown (Cable)"]
        for (i, name) in names.enumerated() {
            let e = try entry(name, m)
            for _ in 0..<2 { for set in m.addExercise(e, mode: m.startingMode(for: e)) { fill(m, set, load: 50 + Double(i) * 10) } }
        }
        m.moveExercise(names[2], to: 0)
        XCTAssertEqual(m.activeBlocks.map(\.exercise), [names[2], names[0], names[1]])
        XCTAssertEqual(m.activeSets.map(\.position), Array(0..<m.activeSets.count))
        m.moveExercise(names[2], to: 99)                                   // past the end: last
        XCTAssertEqual(m.activeBlocks.map(\.exercise), names)
        m.moveExercise(names[1], by: -1)
        XCTAssertEqual(m.activeBlocks.map(\.exercise), [names[1], names[0], names[2]])
        m.setSuperset([names[0], names[2]])
        m.finishWorkout()

        clock.addTimeInterval(3 * 86_400)
        XCTAssertTrue(m.startWorkout(repeating: m.workouts[0]))
        XCTAssertEqual(m.active?.title, "Push day")
        XCTAssertNil(m.active?.routineID); XCTAssertTrue(m.routines.isEmpty)   // nothing saved as a routine
        XCTAssertEqual(m.activeBlocks.map(\.exercise), [names[1], names[0], names[2]])
        XCTAssertEqual(m.block(names[1]).rounds.count, 2)
        XCTAssertEqual(m.block(names[0]).sets.map(\.loadValue), [50, 50])
        XCTAssertEqual(m.superset(of: names[0]), [names[0], names[2]])
        XCTAssertTrue(m.activeSets.allSatisfy { !$0.isDone })
        XCTAssertFalse(m.startWorkout(repeating: m.workouts[0]))               // one at a time
    }

    func testTheReportCountsAnsweredSkippedAndMissedAndWeighsBothSides() throws {
        clock = GarminClient.localTime("2026-11-02 08:10:00", zone: zone)!
        let m = try model()
        let quad = Injury(label: "Right quad", side: .right, onset: Day("2026-08-01")!, tissues: ["quads"])
        m.save(quad)
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 1)                    // Monday morning: answered
        clock = GarminClient.localTime("2026-11-02 17:00:00", zone: zone)!
        m.startWorkout()
        let ext = try entry("Single-Leg Extension (Machine)", m)
        let pair = m.addRound(ext, sides: [.left, .right])
        fill(m, pair[0], load: 60); fill(m, pair[1], load: 20)
        let squat = fill(m, try XCTUnwrap(m.addSet(try entry("Squat (Barbell)", m))), load: 100, reps: 5)
        m.finishWorkout()
        m.skip([try XCTUnwrap(m.dueChecks.first)])                             // right after: skipped
        clock = GarminClient.localTime("2026-11-05 09:00:00", zone: zone)!     // the rest lapsed unanswered
        let report = m.report(for: quad, days: 7)
        XCTAssertEqual(report.answered, 1); XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.missed, 3)                                       // next morning, 24 and 48 hours
        XCTAssertEqual(report.asked, 5)
        // 20 lb x 10 on the right and half of 100 x 5; 60 x 10 on the left and the other half.
        XCTAssertEqual(report.weeklyVolume[0], 450, accuracy: 0.001)
        XCTAssertEqual(report.weeklyOtherVolume?[0] ?? 0, 850, accuracy: 0.001)
        XCTAssertEqual(report.unit, .lb)
        let text = m.reportText(for: quad, days: 7)
        XCTAssertTrue(text.contains("- Questions answered: 1. Skipped: 1. Not answered in time: 3."), text)
        XCTAssertTrue(text.contains("| Nov 5, 2026 |"), text)
        XCTAssertTrue(text.contains("| 450 | 850 |"), text)
        XCTAssertEqual(PainCheckMoment.baseline.label, "Daily check")
        _ = squat
    }

    func testConvertingAUnitCanRoundToARealWeightAndHistoryNeedsTwoWeeks() throws {
        let m = try model()
        XCTAssertFalse(m.hasUsualWeek)
        m.startWorkout()
        let curl = try entry("Biceps Curl (Dumbbell)", m)
        let set = fill(m, try XCTUnwrap(m.addSet(curl)), load: 20)
        m.setUnit(.kg, for: curl.name, converting: true, rounding: true)
        XCTAssertEqual(fresh(m, set).loadValue, 9)                             // 9.07 kg to the half kilogram
        m.setUnit(.lb, for: curl.name, converting: true, rounding: true)
        XCTAssertEqual(fresh(m, set).loadValue, 20)
        m.finishWorkout()
        XCTAssertFalse(m.hasUsualWeek)
        clock.addTimeInterval(14 * 86_400)
        m.refreshClock()
        XCTAssertTrue(m.hasUsualWeek)
        XCTAssertEqual(Day("2026-11-03")?.readable, "Nov 3, 2026")
    }
}
