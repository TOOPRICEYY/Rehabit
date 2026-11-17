import XCTest
@testable import RehabitCore

/// Round three regressions: timed holds, the next set, tempo, routine
/// prescriptions and session effort. Each test fails on the code as it stands.
final class SessionRoundThreeRegressionTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 0)

    func at(_ text: String) -> Date { GarminClient.localTime(text + ":00", zone: zone)! }
    func model() throws -> AppModel {
        AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
    }
    func entry(_ name: String, _ m: AppModel) throws -> CatalogueExercise {
        try XCTUnwrap(m.library.catalogue.first { $0.name == name }, name)
    }
    func current(_ m: AppModel, _ set: WorkoutSet) throws -> WorkoutSet {
        try XCTUnwrap(m.activeSets.first { $0.id == set.id })
    }

    // MARK: Holds

    // Defect: holdRun is never dropped when its set is replaced or its workout ends, so a later stop writes a hold into a reps exercise's set and a finished workout leaves a timer running.
    func testAHoldTimerDoesNotOutliveItsSetOrItsWorkout() throws {
        clock = at("2026-11-02 17:00")
        let m = try model()
        m.startWorkout()
        let plank = try entry("Plank", m), bench = try entry("Bench Press (Barbell)", m)
        var set = try XCTUnwrap(m.addSet(plank))
        set.holdSeconds = 45
        m.update(set)
        XCTAssertTrue(m.startHold(set))
        m.replaceExercise(plank.name, with: bench)           // the set is now a bench press set, by reps
        var press = try current(m, set)
        press.reps = 8
        m.update(press)
        clock.addTimeInterval(45)
        m.stopHold()
        press = try current(m, set)
        XCTAssertEqual(press.kind, .reps, "a stale hold timer turned a bench press set into a hold")
        XCTAssertEqual(press.reps, 8)
        XCTAssertNil(press.holdSeconds)

        let other = try XCTUnwrap(m.addSet(plank))
        m.startHold(other)
        clock.addTimeInterval(10)
        m.finishWorkout()
        XCTAssertNil(m.holdRun, "the workout is finished but a hold of it is still being timed")
    }

    // Defect: finishHold re-marks a set done without clearing restSkippedFor/restAdjust (setDone does), so re-timing a hold whose rest was dismissed gives no rest.
    func testTimingAHoldAgainStartsANewRest() throws {
        clock = at("2026-11-02 17:00")
        let m = try model()
        m.startWorkout()
        var set = try XCTUnwrap(m.addSet(try entry("Plank", m)))
        set.holdSeconds = 45
        m.update(set)
        m.startHold(set); clock.addTimeInterval(45); m.stopHold()
        XCTAssertNotNil(m.rest)
        m.skipRest()
        XCTAssertNil(m.rest)
        clock.addTimeInterval(30)
        m.startHold(try current(m, set)); clock.addTimeInterval(40); m.stopHold()   // done again, just now
        XCTAssertEqual(try current(m, set).holdSeconds, 40)
        XCTAssertEqual(m.rest?.startedAt, clock, "the rest dismissed for the first hold also swallowed the rest after the second")
    }

    // MARK: Next set

    // Defect: nextUp reads lastMarkedDone even after that set is no longer done (a re-timed hold of no time), so it skips the set that was un-done.
    func testNextUpComesBackToASetWhoseHoldCameToNothing() throws {
        clock = at("2026-11-02 17:00")
        let m = try model()
        m.startWorkout()
        let plank = try entry("Plank", m)
        var sets: [WorkoutSet] = []
        for _ in 0..<3 {
            var set = try XCTUnwrap(m.addSet(plank))
            set.holdSeconds = 45
            m.update(set)
            sets.append(set)
        }
        m.startHold(sets[0]); clock.addTimeInterval(45); m.stopHold()
        m.startHold(sets[1]); clock.addTimeInterval(45); m.stopHold()
        m.startHold(try current(m, sets[1])); m.stopHold()   // timed again and stopped at once: not done
        XCTAssertFalse(try current(m, sets[1]).isDone)
        XCTAssertEqual(m.nextUp?.id, sets[1].id, "the set whose mark came off was skipped")
    }

    // Defect: nextUp takes the first set positioned after the last one marked, so with the right half of round 1 done first it jumps to round 2's left and skips round 1's left.
    func testNextUpDoesNotSkipTheOtherHalfOfARound() throws {
        clock = at("2026-11-02 17:00")
        let m = try model()
        m.startWorkout()
        let leg = try entry("Single-Leg Extension (Machine)", m)
        m.addExercise(leg, mode: .perSide)
        m.addExercise(leg, mode: .perSide)
        for set in m.activeSets { var s = set; s.reps = 10; s.loadValue = 20; m.update(s) }
        let rounds = m.block(leg.name).rounds
        XCTAssertEqual(rounds.count, 2)
        let firstLeft = try XCTUnwrap(rounds[0].left), firstRight = try XCTUnwrap(rounds[0].right)
        XCTAssertTrue(m.setDone(true, firstRight))
        XCTAssertEqual(m.nextUp?.id, firstLeft.id, "round 1's left was skipped for round 2's left")
    }

    // MARK: Tempo

    // Defect: WorkoutSet.prescription leaves out tempo though copyPrescription carries it, so going back to "together" silently drops a side whose tempo differs.
    func testSidesThatDifferInTempoAreNotMergedWithoutAsking() throws {
        clock = at("2026-11-02 17:00")
        let m = try model()
        m.startWorkout()
        let leg = try entry("Single-Leg Extension (Machine)", m)
        m.addExercise(leg, mode: .perSide)
        for set in m.activeSets { var s = set; s.reps = 10; s.loadValue = 20; m.update(s) }
        var right = try XCTUnwrap(m.block(leg.name).rounds[0].right)
        right.tempo = "4-1-1-0"                              // the right side lowered slower
        m.update(right)
        XCTAssertTrue(m.mergeLosesData(leg.name), "merging would throw away the right side's tempo without asking")
    }

    // MARK: Routine prescriptions

    // Defect: layOut applies targetCount by the kind copied from last session's set, not by the routine's kind, so "holds of 45 seconds" is laid out as 45 reps.
    func testARoutineHoldPrescriptionIsNotLaidOutAsReps() throws {
        clock = at("2026-11-02 17:00")
        let m = try model()
        let wallSit = CatalogueExercise(name: "Wall Sit Hold", pattern: "", convention: .bodyweight, unilateral: false, kind: .reps)
        m.startWorkout()
        var old = try XCTUnwrap(m.addSet(wallSit))              // last time it was counted in reps
        old.reps = 10
        m.update(old)
        clock.addTimeInterval(1800)
        m.finishWorkout()
        clock = at("2026-11-04 17:00")
        m.save(Routine(name: "Knee", items: [
            RoutineItem(exercise: wallSit.name, pattern: nil, convention: .bodyweight, kind: .hold, rounds: 2, targetCount: 45),
        ]))
        XCTAssertTrue(m.startWorkout(from: m.routines[0]))
        XCTAssertEqual(m.activeSets.count, 2)
        for set in m.activeSets {
            XCTAssertEqual(set.kind, .hold, "a 45 second hold was laid out as \(set.reps ?? 0) reps")
            XCTAssertEqual(set.holdSeconds, 45)
        }
    }

    // MARK: Effort

    // Defect: weekSummary counts effortSessions from sessionLoad, so a session with an effort but no minutes (end equal to start) is left out of the count.
    func testASessionWithAnEffortCountsEvenWithoutMinutes() throws {
        clock = at("2026-11-02 17:00")
        let m = try model()
        m.startWorkout()
        var set = try XCTUnwrap(m.addSet(try entry("Bench Press (Barbell)", m)))
        set.reps = 8; set.loadValue = 100
        m.update(set)
        m.finishWorkout()                                    // finished at the minute it began
        XCTAssertNil(m.workouts[0].minutes)
        m.setEffort(6, for: m.workouts[0])
        XCTAssertEqual(m.workouts[0].effort, 6)
        let week = m.weekSummary()
        XCTAssertEqual(week.sessions, 1)
        XCTAssertEqual(week.effortSessions, 1, "a session with an effort given was not counted as one")
    }

    // Defect: setEffort clamps with max(0, x), which keeps the negative zero that -0.2 rounds to (cleanPain guards against exactly this).
    func testEffortIsNeverNegativeZero() throws {
        clock = at("2026-11-02 17:00")
        let m = try model()
        m.startWorkout()
        var set = try XCTUnwrap(m.addSet(try entry("Bench Press (Barbell)", m)))
        set.reps = 8
        m.update(set)
        clock.addTimeInterval(1800)
        m.finishWorkout()
        m.setEffort(-0.2, for: m.workouts[0])
        let effort = try XCTUnwrap(m.workouts[0].effort)
        XCTAssertEqual(effort, 0)
        XCTAssertEqual(effort.sign, .plus, "effort was stored as -0 and reads \"-0.0\"")
    }
}
