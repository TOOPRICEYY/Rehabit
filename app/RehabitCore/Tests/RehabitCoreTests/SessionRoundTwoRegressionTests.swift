import XCTest
@testable import RehabitCore

/// Adversarial probes on doing a workout after the round 2 core change.
/// Each test fails because of one defect; see its message.
final class SessionRoundTwoRegressionTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 1_790_000_000)

    func model(_ store: Store? = nil) throws -> AppModel {
        AppModel(store: try store ?? Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
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
        return fresh(m, s)
    }
    func makeDrop(_ m: AppModel, _ set: WorkoutSet) {
        m.cycleKind(set); m.cycleKind(set)          // working -> warm-up -> drop
        XCTAssertEqual(fresh(m, set).tag, .drop)
    }

    // MARK: Supersets

    func testReplacingAnExerciseKeepsItsPlaceInTheSuperset() throws {
        let m = try model()
        m.startWorkout()
        let bench = try entry("Bench Press (Barbell)", m), fly = try entry("Chest Fly (Cable)", m)
        let pushdown = try entry("Triceps Pushdown (Cable)", m)
        let b1 = fill(m, try XCTUnwrap(m.addSet(bench)), load: 100)
        fill(m, try XCTUnwrap(m.addSet(fly)), load: 30)
        m.setSuperset([bench.name, fly.name])
        m.replaceExercise(fly.name, with: pushdown)        // the fly station is taken
        XCTAssertEqual(m.superset(of: pushdown.name), [bench.name, pushdown.name],
                       "replaceExercise moves the link override but not the superset: the replacement is no longer in it")
        m.setDone(true, b1)
        XCTAssertNil(m.rest, "rest ran after the first exercise of a superset whose partner was replaced")
    }

    func testInASupersetTheRestComesAfterTheDropSetThatEndsTheRound() throws {
        let m = try model()
        m.startWorkout()
        let bench = try entry("Bench Press (Barbell)", m), fly = try entry("Chest Fly (Cable)", m)
        let a = (0..<2).map { _ in fill(m, m.addSet(bench)!, load: 100) }
        let b = (0..<4).map { i in fill(m, m.addSet(fly)!, load: i % 2 == 0 ? 40 : 25) }
        makeDrop(m, b[1]); makeDrop(m, b[3])
        m.setSuperset([bench.name, fly.name])
        // Round 1: bench, fly, fly drop. Then rest. Round 2 the same.
        m.setDone(true, a[0]); clock.addTimeInterval(30)
        m.setDone(true, b[0]); clock.addTimeInterval(30)
        m.setDone(true, b[1]); clock.addTimeInterval(1)
        XCTAssertEqual(m.rest?.setID, b[1].id,
                       "no rest after the drop set that ends superset round 1: the drop is counted as a turn of its own, so bench looks behind")
        clock.addTimeInterval(120)
        m.setDone(true, a[1]); clock.addTimeInterval(1)
        XCTAssertNil(m.rest, "a rest ran between bench and fly in superset round 2")
    }

    func testARemovedExerciseLeavesItsSuperset() throws {
        let m = try model()
        m.startWorkout()
        let bench = try entry("Bench Press (Barbell)", m), fly = try entry("Chest Fly (Cable)", m)
        fill(m, try XCTUnwrap(m.addSet(bench)), load: 100)
        let flySet = try XCTUnwrap(m.addSet(fly))
        m.setSuperset([bench.name, fly.name])
        m.removeExercise(fly.name)
        XCTAssertNil(m.superset(of: bench.name), "bench is still shown in a superset with an exercise that was removed")
        // A row left blank is dropped at the finish; the finished workout should not name it in a superset either.
        let n = try model()
        n.startWorkout()
        fill(n, try XCTUnwrap(n.addSet(bench)), load: 100)
        _ = n.addSet(fly)
        n.setSuperset([bench.name, fly.name])
        n.finishWorkout()
        XCTAssertNil(n.workouts.first?.supersets, "the finished workout keeps a superset with an exercise it has no sets of")
        _ = flySet
    }

    func testARoutineSupersetSurvivesADifferenceInCase() throws {
        let m = try model()
        let routine = Routine(name: "Push", items: [
            RoutineItem(exercise: "bench press (barbell)", pattern: nil, rounds: 2, group: 0),
            RoutineItem(exercise: "Chest Fly (Cable)", pattern: nil, rounds: 2, group: 0),
        ])
        m.save(routine)
        XCTAssertTrue(m.startWorkout(from: try XCTUnwrap(m.routines.first)))
        XCTAssertEqual(m.activeBlocks.map(\.exercise), ["Bench Press (Barbell)", "Chest Fly (Cable)"])
        XCTAssertNotNil(m.superset(of: "Bench Press (Barbell)"),
                        "layOut maps the item to the catalogue name but groups the superset under the routine's spelling: \(String(describing: m.active?.supersets))")
    }

    // MARK: Routines and repeats

    func testARoutineWithNegativeWarmupsCannotBeStored() throws {
        // startWorkout(from:) runs `for _ in 0..<item.warmups`, which traps on a negative count.
        // The init clamps, but the property is `var` and Codable bypasses the init (sync, merge).
        let json = #"{"id":"x","exercise":"Bench Press (Barbell)","convention":"total","unilateral":false,"kind":"reps","mode":"together","rounds":3,"warmups":-1,"notes":""}"#
        let decoded = try JSONDecoder().decode(RoutineItem.self, from: Data(json.utf8))
        let m = try model()
        var item = RoutineItem(exercise: "Bench Press (Barbell)", pattern: "horizontal_push")
        item.warmups = -1
        m.save(Routine(name: "R", items: [item]))
        let stored = try XCTUnwrap(m.routines.first?.items.first)
        XCTAssertGreaterThanOrEqual(stored.warmups, 0, "a routine with -1 warm-ups is saved; starting it crashes (0..<-1)")
        XCTAssertGreaterThanOrEqual(decoded.warmups, 0, "a routine read from sync with -1 warm-ups is kept; starting it crashes")
    }

    func testRepeatingAWorkoutOfOnlyWarmupsAddsNoWorkingSet() throws {
        let m = try model()
        m.startWorkout(title: "Mobility")
        let bench = try entry("Bench Press (Barbell)", m)
        for _ in 0..<2 {
            var s = fill(m, try XCTUnwrap(m.addSet(bench)), load: 45)
            s.isWarmup = true; m.update(s)
        }
        m.finishWorkout()
        clock.addTimeInterval(86_400)
        XCTAssertTrue(m.startWorkout(repeating: m.workouts[0]))
        let sets = m.block(bench.name).sets
        XCTAssertEqual(sets.count, 2, "a repeat of two warm-up sets laid out \(sets.count) sets")
        XCTAssertEqual(sets.filter { !$0.isWarmup }.count, 0, "a working set was invented")
        XCTAssertEqual(sets.filter(\.isWarmup).compactMap(\.loadValue), [45, 45],
                       "the warm-ups were halved from the warm-up load: \(sets.map(\.loadValue))")
    }

    // MARK: Copies

    func testASetAddedAfterADropSetStartsFromTheWorkingLoad() throws {
        let m = try model()
        m.startWorkout()
        let bench = try entry("Bench Press (Barbell)", m)
        fill(m, try XCTUnwrap(m.addSet(bench)), load: 100)
        let drop = fill(m, try XCTUnwrap(m.addSet(bench)), load: 70)
        makeDrop(m, drop)
        let next = try XCTUnwrap(m.addSet(bench))
        XCTAssertNil(next.tag)
        XCTAssertEqual(next.loadValue, 100,
                       "the next working set copied the drop set's lighter load (as a warm-up's is not copied)")
    }

    // MARK: Injured side

    func testSwitchingOneSideToPerSideDoesNotGiveTheInjuredSideTheHealthyLoad() throws {
        let m = try model()
        let ext = try entry("Single-Leg Extension (Machine)", m)
        // Last time: the left alone at 60.
        clock.addTimeInterval(-86_400)
        m.startWorkout()
        fill(m, try XCTUnwrap(m.addSet(ext, side: .left)), load: 60, reps: 12)
        m.finishWorkout()
        clock.addTimeInterval(86_400)
        m.save(Injury(label: "Right quad", side: .right, onset: Day("2026-05-01")!, tissues: ["quads"]))
        m.startWorkout()
        let left = m.addExercise(ext, mode: .leftOnly)
        XCTAssertEqual(left.first?.loadValue, 60)
        // The person decides to try the right today.
        m.setSideMode(.perSide, for: ext.name)
        let right = try XCTUnwrap(m.activeSets.first { $0.side == .right })
        XCTAssertNil(right.loadValue, "the injured right was given the healthy left's 60 lb by addTwin")
    }

    // MARK: Side mode

    func testGoingBackToTogetherDoesNotKeepAnEmptyHalfMarkedDone() throws {
        let m = try model()
        m.startWorkout()
        let ext = try entry("Single-Leg Extension (Machine)", m)
        let pair = m.addExercise(ext, mode: .perSide)
        m.setLinked(false, for: ext.name)
        fill(m, pair[0], load: nil, reps: nil)          // left not done today
        fill(m, pair[1], load: 20, reps: 10)
        XCTAssertTrue(m.setDone(true, fresh(m, pair[1])))
        m.setSideMode(.together, for: ext.name)         // default keep: .left
        let kept = try XCTUnwrap(m.activeSets.first)
        XCTAssertFalse(kept.isDone && (kept.count ?? 0) <= 0,
                       "the empty left half was kept and marked done (reps nil) while the done right half (20 x 10) was deleted")
    }

    // MARK: Done and rest

    func testAnUntickedWarmupDoesNotMakeAnAlternatorLookOneSidedAtATime() throws {
        let m = try model()
        m.startWorkout()
        let curl = try entry("Biceps Curl (Cable)", m)
        let warm = m.addRound(curl, sides: [.left, .right]).map { fill(m, $0, load: 10) }
        for s in warm { var w = fresh(m, s); w.isWarmup = true; m.update(w) }
        let work = m.addRound(curl, sides: [.left, .right]).map { fill(m, $0, load: 20) }
        m.setDone(true, warm[0])                        // ticked the left warm-up, not the right
        clock.addTimeInterval(60)
        m.setDone(true, work[0])
        XCTAssertNil(m.rest, "a warm-up round is taken as proof of one side at a time: rest ran with the right working half still to do")
    }

    func testNaNRepsAreNotMarkedDone() throws {
        let m = try model()
        m.startWorkout()
        let set = fill(m, try XCTUnwrap(m.addSet(try entry("Bench Press (Barbell)", m))), load: 100, reps: .nan)
        XCTAssertFalse(m.setDone(true, set), "a set whose reps are NaN was marked done (NaN <= 0 is false)")
    }

    func testAHoldStoppedAtZeroIsNotDone() throws {
        let m = try model()
        m.startWorkout()
        let set = try XCTUnwrap(m.addSet(try entry("Plank", m)))
        m.finishHold(set, seconds: 0)
        XCTAssertFalse(fresh(m, set).isDone, "finishHold marks a 0-second hold done, which setDone refuses")
    }

    func testTheRestFollowsTheSetJustMarkedWhenTheClockWentBack() throws {
        let m = try model()
        m.startWorkout()
        let bench = try entry("Bench Press (Barbell)", m)
        let one = fill(m, try XCTUnwrap(m.addSet(bench)), load: 100)
        let two = fill(m, try XCTUnwrap(m.addSet(bench)), load: 100)
        m.setDone(true, one)
        clock.addTimeInterval(-600)                     // the phone's clock was corrected back ten minutes
        m.setDone(true, two)
        XCTAssertEqual(m.rest?.setID, two.id, "the rest stays on the earlier set and does not count down for ten minutes")
    }

    func testUnmarkingAndMarkingAgainStartsAFreshRest() throws {
        let m = try model()
        m.startWorkout()
        let bench = try entry("Bench Press (Barbell)", m)
        let one = fill(m, try XCTUnwrap(m.addSet(bench)), load: 100)
        m.setDone(true, one)
        m.adjustRest(by: -150)                          // ended the rest early with the minus button
        XCTAssertNil(m.rest)
        m.setDone(false, one)                           // ticked by mistake: not done yet
        clock.addTimeInterval(90)
        m.setDone(true, one)                            // now done for real
        XCTAssertEqual(m.rest?.seconds, 120,
                       "the adjustment of a countdown that was undone still applies to the new one (no rest at all)")
    }

    // MARK: Plates

    func testPlatesFindAnExactLoadWhenOneExists() {
        // A home gym with 20 kg and 15 kg plates, a 20 kg bar, 80 kg wanted: 15 + 15 a side.
        let load = Plates.load(total: 80, bar: 20, plates: [20, 15])
        XCTAssertEqual(load.short, 0, "greedy took a 20 and then could not make 10: says 20 kg short of 80 \(load.perSide)")
    }
}
