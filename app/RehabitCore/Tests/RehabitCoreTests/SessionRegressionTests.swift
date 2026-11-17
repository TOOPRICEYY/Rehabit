import XCTest
@testable import RehabitCore

/// Cases found by an adversarial test pass on sets, rest, units and progress (round 1).
final class SessionRegressionTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 1_790_000_000)

    func model(_ store: Store? = nil) throws -> AppModel {
        AppModel(store: try store ?? Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
    }
    func entry(_ name: String, _ m: AppModel) throws -> CatalogueExercise {
        try XCTUnwrap(m.library.catalogue.first { $0.name == name }, name)
    }
    @discardableResult
    func add(_ m: AppModel, _ name: String, side: Side? = nil, load: Double?, reps: Double? = 10,
             warmup: Bool = false, unit: WeightUnit? = nil) throws -> WorkoutSet {
        var set = try XCTUnwrap(m.addSet(try entry(name, m), side: side))
        set.loadValue = load; set.reps = reps; set.isWarmup = warmup
        if let unit { set.loadUnit = unit }
        m.update(set)
        return m.activeSets.first { $0.id == set.id }!
    }
    func earlier(_ m: AppModel, days: Double = 1, _ body: () throws -> Void) rethrows {
        clock.addTimeInterval(-86_400 * days)
        m.startWorkout()
        try body()
        m.finishWorkout()
        clock.addTimeInterval(86_400 * days)
    }

    // MARK: Done marks

    func testSplittingADoneSetKeepsBothHalvesDone() throws {
        let m = try model()
        m.startWorkout()
        let a = try add(m, "Leg Extension (Machine)", load: 50)
        try add(m, "Leg Extension (Machine)", load: 50)
        m.setDone(true, a)
        m.split(m.activeSets.first { $0.id == a.id }!)
        let halves = m.activeSets.filter { $0.side != .both }
        XCTAssertEqual(halves.count, 2)
        XCTAssertEqual(halves.filter(\.isDone).count, 2, "right half of a done set comes back as planned")
        m.finishWorkout(removingUnfinished: true)
        XCTAssertEqual(m.sets(of: m.workouts[0]).filter { $0.side == .right }.count, 1, "right half deleted")
    }

    func testPerSideModeKeepsDoneMarks() throws {
        let m = try model()
        m.startWorkout()
        let a = try add(m, "Leg Extension (Machine)", load: 50)
        m.setDone(true, a)
        m.setSideMode(.perSide, for: "Leg Extension (Machine)")
        XCTAssertTrue(m.activeSets.allSatisfy(\.isDone), "twin made by per-side mode is not done")
    }

    func testTogetherKeepsTheDoneHalf() throws {
        let m = try model()
        m.startWorkout()
        let rounds = m.addExercise(try entry("Single-Leg Extension (Machine)", m), mode: .perSide)
        m.setDone(true, rounds[1])   // only the right was ticked
        m.setSideMode(.together, for: "Single-Leg Extension (Machine)")
        XCTAssertTrue(m.activeSets[0].isDone, "merging to together dropped the right half's done mark")
    }

    func testDoneMarksSurviveRelaunchAndMerge() throws {
        let store = try Store(path: ":memory:")
        let m = try model(store)
        m.startWorkout()
        let a = try add(m, "Bench Press (Barbell)", load: 100)
        try add(m, "Bench Press (Barbell)", load: 100)
        m.setDone(true, a)
        let again = try model(store)
        XCTAssertEqual(again.unfinishedSets.count, 1)
        XCTAssertEqual(again.activeSets.first { $0.id == a.id }?.completedAt, clock)
        let other = try model(try Store(path: ":memory:"))
        _ = other.merge(try XCTUnwrap(m.exportJSON()))
        XCTAssertEqual(other.activeSets.first { $0.id == a.id }?.completedAt, clock)
        XCTAssertEqual(other.unfinishedSets.count, 1)
    }

    // MARK: Prefill

    func testAnInjuredRightSideDoesNotStartFromTheHealthyLeftInARound() throws {
        let m = try model()
        try earlier(m) { try add(m, "Single-Leg Extension (Machine)", side: .left, load: 60, reps: 12) }
        m.save(Injury(label: "Quad", side: .right, onset: Day("2026-05-01")!, tissues: ["quads"]))
        m.startWorkout()
        let added = m.addExercise(try entry("Single-Leg Extension (Machine)", m), mode: .perSide)
        XCTAssertEqual(added.map(\.side), [.left, .right])
        XCTAssertNil(m.activeSets.first { $0.side == .right }?.loadValue, "injured right got the healthy left's 60")
    }

    // MARK: Warm-up

    func testAWarmUpIsNeverHeavierThanTheWorkingSet() throws {
        let m = try model()
        m.startWorkout()
        try add(m, "Lateral Raise (Dumbbell)", load: 3)        // 3 lb rehab dumbbell
        let warm = m.addWarmupRound(to: m.block("Lateral Raise (Dumbbell)"))
        XCTAssertLessThanOrEqual(try XCTUnwrap(warm.first?.loadValue), 3, "warm-up heavier than working set")
    }

    // MARK: Rest

    func testRestNeverExceedsItsLengthWhenTheClockGoesBack() throws {
        let m = try model()
        m.startWorkout()
        let a = try add(m, "Bench Press (Barbell)", load: 100)
        m.setDone(true, a)
        clock.addTimeInterval(-600)        // the phone's clock is corrected back ten minutes
        let rest = try XCTUnwrap(m.rest)
        XCTAssertLessThanOrEqual(rest.remaining(at: clock), Double(rest.seconds), "countdown shows 12:00 of a 2:00 rest")
    }

    // MARK: Load step

    func testOneMistypedLoadDoesNotChangeTheStepForGood() throws {
        let m = try model()
        try earlier(m, days: 3) { for l in [100.0, 105, 110, 115] { try add(m, "Bench Press (Barbell)", load: l) } }
        try earlier(m, days: 2) { try add(m, "Bench Press (Barbell)", load: 101) }   // typo for 110
        XCTAssertEqual(m.loadStep(for: "Bench Press (Barbell)", unit: .lb), 5, "one typo makes the + button move 1 lb")
    }

    // MARK: Unit

    func testUnitRoundTripDoesNotDrift() throws {
        let m = try model()
        m.startWorkout()
        try add(m, "Bench Press (Barbell)", load: 100)
        try add(m, "Lateral Raise (Dumbbell)", load: 2.5)
        m.setUnit(.kg, for: "Bench Press (Barbell)"); m.setUnit(.lb, for: "Bench Press (Barbell)")
        m.setUnit(.kg, for: "Lateral Raise (Dumbbell)"); m.setUnit(.lb, for: "Lateral Raise (Dumbbell)")
        XCTAssertEqual(m.block("Bench Press (Barbell)").sets[0].loadValue, 100)
        XCTAssertEqual(m.block("Lateral Raise (Dumbbell)").sets[0].loadValue, 2.5)
    }

    func testShowingTheSameWeightInKgIsNotARecord() throws {
        let m = try model()
        try earlier(m) { try add(m, "Bench Press (Barbell)", load: 100, reps: 5) }
        m.startWorkout()
        try add(m, "Bench Press (Barbell)", load: 100, reps: 5)
        m.setUnit(.kg, for: "Bench Press (Barbell)")
        XCTAssertEqual(m.recordsBroken(by: m.activeSets[0]), [], "100 lb shown as 45.5 kg reads as a new heaviest")
    }

    // MARK: Replace

    func testReplacingWithABodyWeightExerciseDoesNotKeepABarbellLoad() throws {
        let m = try model()
        m.startWorkout()
        try add(m, "Bench Press (Barbell)", load: 135)
        m.replaceExercise("Bench Press (Barbell)", with: try entry("Push-Up", m))
        XCTAssertEqual(m.activeSets[0].convention, .bodyweight, "a push-up is logged as 135 lb total")
        m.replaceExercise("Push-Up", with: try entry("Plank", m))
        XCTAssertEqual(m.activeSets[0].kind, .hold, "a plank is logged as reps")
    }

    // MARK: Import conventions

    func testMoreAssistanceIsNotAHeavierPullUp() {
        let match = ExerciseMatcher.entry(for: "Assisted Pull Up (Machine)", in: .standard).entry
        let w = Workout(start: clock, end: clock, zone: zone)
        func set(_ assist: Double) -> WorkoutSet {
            WorkoutSet(workout: w, position: 0, exercise: match.name, pattern: match.pattern, loadValue: assist,
                       loadUnit: .kg, convention: match.convention)
        }
        let ledger = Ledger(library: .standard), profile = Profile(bodyweightKg: 80)
        let heavy = ledger.loadKg(set(40), profile: profile) ?? 0, light = ledger.loadKg(set(10), profile: profile) ?? 0
        XCTAssertLessThanOrEqual(heavy, light, "40 kg of assistance counted as more load than 10 kg (convention \(match.convention))")
    }

    // MARK: Pairs

    func testRemovingOneHalfLeavesTheOtherRoundsAsTheyWere() throws {
        let m = try model()
        m.startWorkout()
        let entry = try entry("Single-Leg Extension (Machine)", m)
        let first = m.addExercise(entry, mode: .perSide)
        let second = m.addRound(to: m.block(entry.name))
        m.removeSet(id: first[0].id)                              // the first round's left half
        let rounds = m.block(entry.name).rounds
        XCTAssertEqual(rounds.count, 2)
        XCTAssertNil(rounds[0].left); XCTAssertEqual(rounds[0].right?.id, first[1].id)
        XCTAssertEqual(rounds[1].left?.id, second[0].id); XCTAssertEqual(rounds[1].right?.id, second[1].id)
        // Filling the gap puts the new left beside the right it belongs to.
        m.fillMissingSide(of: rounds[0])
        let filled = m.block(entry.name).rounds
        XCTAssertEqual(filled.count, 2)
        XCTAssertEqual(filled.first { $0.right?.id == first[1].id }?.left?.pairID, first[1].pairID)
        // Sets from before pairs were kept (no pair id) still pair in order.
        let w = Workout(start: clock, zone: zone)
        let old = [Side.left, .right, .left, .right].enumerated().map {
            WorkoutSet(workout: w, position: $0.offset, exercise: "X", pattern: nil, side: $0.element)
        }
        XCTAssertEqual(ExerciseBlock(exercise: "X", sets: old).rounds.map { [$0.left?.position, $0.right?.position] },
                       [[0, 1], [2, 3]])
    }

    func testTheSecondOfThreeEqualSetsIsNotARecordAgain() throws {
        let m = try model()
        try earlier(m) { try add(m, "Bench Press (Barbell)", load: 100, reps: 5) }
        m.startWorkout()
        let sets = try (0..<3).map { _ in try add(m, "Bench Press (Barbell)", load: 110, reps: 5) }
        XCTAssertEqual(m.recordsBroken(by: sets[0]), [.heaviestLoad, .bestE1RM])
        XCTAssertEqual(m.recordsBroken(by: sets[1]), [])
        XCTAssertEqual(m.recordsBroken(by: sets[2]), [])
    }

    func testACustomExerciseWithNoMovementTreatsEveryInjuredSideAsInjured() throws {
        let m = try model()
        let custom = CatalogueExercise(name: "Knee Thing", pattern: "", convention: .total, unilateral: true)
        clock.addTimeInterval(-86_400); m.startWorkout()
        var left = try XCTUnwrap(m.addSet(custom, side: .left)); left.loadValue = 40; left.reps = 10; m.update(left)
        m.finishWorkout(); clock.addTimeInterval(86_400)
        m.save(Injury(label: "Quad", side: .right, onset: Day("2026-05-01")!, tissues: ["quads"]))
        m.startWorkout()
        _ = m.addExercise(custom, mode: .perSide)
        XCTAssertNil(m.activeSets.first { $0.side == .right }?.loadValue)
    }

    // MARK: Calendar

    func testWeekAndStreakAcrossYearEndAndDST() throws {
        let z = TimeZone(identifier: "America/New_York")!
        clock = Day("2027-01-02")!.start(in: z).addingTimeInterval(20 * 3600)
        let m = AppModel(store: try Store(path: ":memory:"), zone: z, now: { [unowned self] in self.clock })
        for daysBack in [0.0, 7, 14, 21] {
            try earlier(m, days: daysBack) { try add(m, "Bench Press (Barbell)", load: 100) }
        }
        XCTAssertEqual(m.weeklyStreak(), 4)
        XCTAssertEqual(m.weekSummary().start, Day("2026-12-27"))
        // DST: 2026-11-01 in New York
        clock = Day("2026-11-07")!.start(in: z).addingTimeInterval(23.5 * 3600)
        let m2 = AppModel(store: try Store(path: ":memory:"), zone: z, now: { [unowned self] in self.clock })
        try earlier(m2, days: 6) { try add(m2, "Bench Press (Barbell)", load: 100) }   // 2026-11-01 23:30
        XCTAssertEqual(m2.weekSummary().sessions, 1)
        XCTAssertEqual(m2.workouts.first?.startDay, Day("2026-11-01"))
    }
}
