import XCTest
@testable import RehabitCore

/// What the simulator testers of round two needed from the core.
final class SimulatorRoundTwoRegressionTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 1_790_000_000)

    func model() throws -> AppModel {
        AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
    }
    func entry(_ name: String, _ m: AppModel) throws -> CatalogueExercise {
        try XCTUnwrap(m.library.catalogue.first { $0.name == name }, name)
    }
    @discardableResult
    func add(_ m: AppModel, _ exercise: CatalogueExercise, load: Double?, reps: Double? = 10, side: Side? = nil,
             warmup: Bool = false, done: Bool = false) throws -> WorkoutSet {
        var set = try XCTUnwrap(m.addSet(exercise, side: side))
        set.loadValue = load; set.reps = reps; set.isWarmup = warmup
        m.update(set)
        if done { XCTAssertTrue(m.setDone(true, set)) }
        return try XCTUnwrap(m.activeSets.first { $0.id == set.id })
    }

    func testTheLoadStepIgnoresWarmUpsAndTheNumberBeingTyped() throws {
        let m = try model()
        let bench = try entry("Bench Press (Barbell)", m)
        m.startWorkout()
        try add(m, bench, load: 45, warmup: true, done: true)
        try add(m, bench, load: 95, warmup: true, done: true)
        let typed = try add(m, bench, load: 225)                          // typed, not yet done
        XCTAssertEqual(m.loadStep(for: bench.name, unit: .lb), 5)
        XCTAssertEqual(m.stepped(typed, load: 1).loadValue, 230)
        // Working weights far apart on different days are not a step either.
        m.setDone(true, typed)
        clock.addTimeInterval(1800); m.finishWorkout()
        for load in [135.0, 185] {
            clock.addTimeInterval(86_400)
            m.startWorkout(); try add(m, bench, load: load, done: true)
            clock.addTimeInterval(1800); m.finishWorkout()
        }
        XCTAssertEqual(m.loadStep(for: bench.name, unit: .lb), 5)
    }

    func testSidesTrainedAboveTwelveRepsAreStillCompared() throws {
        let m = try model()
        let raise = try entry("Single-Leg Extension (Machine)", m)
        m.startWorkout()
        try add(m, raise, load: 10, reps: 15, side: .left)
        try add(m, raise, load: 5, reps: 15, side: .right)
        clock.addTimeInterval(1800); m.finishWorkout()
        let point = try XCTUnwrap(m.symmetry(exercise: raise.name).first)
        XCTAssertEqual(point.measure, .loadReps)
        XCTAssertEqual(point.ratio(injured: .right) ?? 0, 0.5, accuracy: 0.001)
    }

    func testDiscardingAnUntouchedRepeatKeepsNothing() throws {
        let m = try model()
        let bench = try entry("Bench Press (Barbell)", m)
        m.startWorkout(); try add(m, bench, load: 100); clock.addTimeInterval(1800); m.finishWorkout()
        clock.addTimeInterval(86_400)
        XCTAssertTrue(m.startWorkout(repeating: m.workouts[0]))
        XCTAssertEqual(m.activeSets.map(\.planned), [true])
        m.discardWorkout()
        XCTAssertTrue(m.recentlyDeleted.isEmpty, "a copy made only of last time's numbers was kept as a workout")
        // Touched, it is kept.
        XCTAssertTrue(m.startWorkout(repeating: m.workouts[0]))
        var set = m.activeSets[0]; set.reps = 9
        m.update(set)
        XCTAssertNil(m.activeSets[0].planned)
        m.discardWorkout()
        XCTAssertEqual(m.recentlyDeleted.count, 1)
    }

    func testASetDoneWithNoWeightTakesTheWeightOfTheSetAbove() throws {
        let m = try model()
        let curl = try entry("Biceps Curl (Cable)", m)
        m.startWorkout()
        try add(m, curl, load: 30, side: .left, done: true)
        var bare = try XCTUnwrap(m.addSet(curl, side: .left))
        bare.loadValue = nil; bare.reps = 10
        m.update(bare)
        XCTAssertTrue(m.setDone(true, bare))
        XCTAssertEqual(m.activeSets.last?.loadValue, 30)
    }

    func testAWarmUpTypedAndNotTickedIsNotCountedAsUnfinished() throws {
        let m = try model()
        let bench = try entry("Bench Press (Barbell)", m)
        m.startWorkout()
        let warm = try add(m, bench, load: 45, warmup: true)
        try add(m, bench, load: 135, done: true)
        let open = try add(m, bench, load: 135)
        XCTAssertEqual(m.unfinishedSets.map(\.id), [open.id])
        clock.addTimeInterval(1800)
        m.finishWorkout(removingUnfinished: true)
        XCTAssertTrue(m.sets(of: m.workouts[0]).contains { $0.id == warm.id }, "a warm-up the person typed was removed")
    }

    func testTheFirstSessionOfAnExerciseSetsNoRecord() throws {
        let m = try model()
        let plank = try entry("Plank", m)
        m.startWorkout()
        var first = try XCTUnwrap(m.addSet(plank)); first.holdSeconds = 30; m.update(first)
        var second = try XCTUnwrap(m.addSet(plank)); second.holdSeconds = 45; m.update(second)
        XCTAssertTrue(m.recordsBroken(by: try XCTUnwrap(m.activeSets.last)).isEmpty)
    }

    func testASetCanBeGivenItsKindDirectly() throws {
        let m = try model()
        m.startWorkout()
        let set = try add(m, try entry("Bench Press (Barbell)", m), load: 100)
        m.setLabel(.drop, for: set)
        XCTAssertEqual(m.activeSets[0].label, .drop); XCTAssertFalse(m.activeSets[0].isWarmup)
        m.setLabel(.warmup, for: set)
        XCTAssertEqual(m.activeSets[0].label, .warmup); XCTAssertNil(m.activeSets[0].tag)
        m.setLabel(.working, for: set)
        XCTAssertEqual(m.activeSets[0].label, .working)
    }

    func testAnExercisePageHasOneUnitAndSaysWhatItsLoadsMean() throws {
        let m = try model()
        m.profile.unit = .lb
        let raise = try entry("Bench Press (Barbell)", m)
        m.startWorkout()
        var set = try add(m, raise, load: 9)
        set.loadUnit = .kg; m.update(set)
        XCTAssertEqual(m.displayUnit(for: raise.name), .kg)
        XCTAssertEqual(m.displayUnit(for: "Never Logged"), .lb)
        XCTAssertNil(m.loadNote(for: raise.name))
        XCTAssertTrue(m.loadNote(for: "Assisted Dip (Machine)")?.contains("Add it in Settings") ?? false)
        m.profile.bodyweightKg = 80
        XCTAssertTrue(m.loadNote(for: "Assisted Dip (Machine)")?.contains("less the assistance") ?? false)
    }

    func testAReportDoesNotShowWeeksFromBeforeAnythingWasRecorded() throws {
        let m = try model()
        let leg = try entry("Single-Leg Extension (Machine)", m)
        m.save(Injury(label: "Right quad", side: .right, onset: Day(clock, in: zone), tissues: ["quads"]))
        m.startWorkout(); try add(m, leg, load: 20, side: .right); clock.addTimeInterval(1800); m.finishWorkout()
        let report = m.report(for: m.injuries[0], days: 84)
        XCTAssertEqual(report.weeklyLoad.count, 1, "weeks before the first record were shown as weeks of no load")
    }
}
