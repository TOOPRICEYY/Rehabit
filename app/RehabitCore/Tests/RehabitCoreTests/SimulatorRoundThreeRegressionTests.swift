import XCTest
@testable import RehabitCore

/// What the simulator testers of round three needed from the core.
final class SimulatorRoundThreeRegressionTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 0)

    func at(_ text: String) -> Date { GarminClient.localTime(text + ":00", zone: zone)! }
    func model() throws -> AppModel {
        AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
    }
    func entry(_ name: String, _ m: AppModel) throws -> CatalogueExercise {
        try XCTUnwrap(m.library.catalogue.first { $0.name == name }, name)
    }
    @discardableResult
    func session(_ m: AppModel, minutes: Double = 30, load: Double = 20, pain: Double? = nil) throws -> Workout {
        let leg = try entry("Single-Leg Extension (Machine)", m)
        m.startWorkout()
        var set = try XCTUnwrap(m.addSet(leg, side: .right))
        set.loadValue = load; set.reps = 10; set.pain = pain
        m.update(set)
        clock.addTimeInterval(minutes * 60)
        m.finishWorkout()
        return m.workouts[0]
    }
    func quad(_ onset: String, plan: InjuryPlan? = nil) -> Injury {
        var injury = Injury(label: "Right quad", side: .right, onset: Day(onset)!, tissues: ["quads"])
        injury.plan = plan
        return injury
    }

    func testPainLoggedOnTheWayInIsTheLevelBefore() throws {
        clock = at("2026-11-10 10:00")
        let m = try model()
        let injury = quad("2026-10-01", plan: InjuryPlan(rule: PainRule(settleHours: 24)))
        m.save(injury)
        m.logPain([(injury: injury, pain: 1, type: nil)])
        clock = at("2026-11-10 10:01")
        let workout = try session(m, minutes: 1)
        XCTAssertEqual(try XCTUnwrap(m.settling(for: workout).first).baseline, 1)
    }

    func testLimitsCountOnlySessionsSinceTheInjuryBegan() throws {
        clock = at("2026-10-21 17:00")
        let m = try model()
        try session(m, pain: 2)
        clock = at("2026-10-24 17:00"); try session(m, pain: 2)
        clock = at("2026-10-29 17:00"); try session(m, pain: 2)
        m.save(quad("2026-10-28", plan: InjuryPlan(rule: PainRule(duringMax: 4))))
        clock = at("2026-11-01 09:00")
        XCTAssertEqual(m.ruleChecks(for: m.injuries[0]).map(\.day), [Day("2026-10-29")!])
    }

    func testAHoldHeldWellPastItsTargetIsSavedAsHeld() throws {
        clock = at("2026-11-10 10:00")
        let m = try model()
        m.startWorkout()
        var set = try XCTUnwrap(m.addSet(try entry("Plank", m)))
        set.holdSeconds = 5
        m.update(set)
        m.startHold(set); clock.addTimeInterval(9); m.stopHold()
        XCTAssertEqual(m.activeSets[0].holdSeconds, 9)
    }

    func testTheCalendarGivesTheDaysWorstFlare() throws {
        clock = at("2026-11-10 08:05")
        let m = try model()
        let injury = quad("2026-10-01")
        m.save(injury)
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 2)
        clock = at("2026-11-10 13:00")
        m.logPain([(injury: injury, pain: 6, type: nil)])
        let day = try XCTUnwrap(m.calendar(year: 2026, month: 11).first { $0.day == Day("2026-11-10") })
        XCTAssertEqual(day.painHigh, 2); XCTAssertEqual(day.flareHigh, 6)
    }

    func testAJumpIsMeasuredFromTheSetBeforeItToday() throws {
        clock = at("2026-11-04 17:00")
        let m = try model()
        try session(m, load: 12.5)
        clock = at("2026-11-10 17:00")
        let leg = try entry("Single-Leg Extension (Machine)", m)
        m.startWorkout()
        var first = try XCTUnwrap(m.addSet(leg, side: .right))
        first.loadValue = 15; first.reps = 10; m.update(first)
        XCTAssertTrue(m.setDone(true, first))
        var second = try XCTUnwrap(m.addSet(leg, side: .right))
        second.loadValue = 17.5; second.reps = 10; m.update(second)
        let jump = m.advice(for: second).first { $0.kind == .intensityJump }
        XCTAssertFalse(jump?.detail.contains("40") ?? false, jump?.detail ?? "")
    }

    func testSetsLaidOutAndNeverTouchedAreAskedAboutWithNothingTicked() throws {
        clock = at("2026-11-04 17:00")
        let m = try model()
        let bench = try entry("Bench Press (Barbell)", m)
        m.startWorkout()
        var old = try XCTUnwrap(m.addSet(bench)); old.loadValue = 35; old.reps = 10; m.update(old)
        clock.addTimeInterval(1800); m.finishWorkout()
        clock = at("2026-11-06 17:00")
        m.save(Routine(name: "Push", items: [RoutineItem(exercise: bench.name, pattern: bench.pattern, rounds: 3, targetCount: 12)]))
        XCTAssertTrue(m.startWorkout(from: m.routines[0]))
        XCTAssertEqual(m.unfinishedSets.count, 3)
        m.finishWorkout(removingUnfinished: true)
        XCTAssertEqual(m.workouts.count, 1, "three sets nobody did were saved as a workout")
    }

    func testTheFirstStepUpOnABarbellIsTheBar() throws {
        let m = try model()
        m.startWorkout()
        let set = try XCTUnwrap(m.addSet(try entry("Squat (Barbell)", m)))
        XCTAssertEqual(m.stepped(set, load: 1).loadValue, 45)
        XCTAssertEqual(m.stepped(m.stepped(set, load: 1), load: 1).loadValue, 50)
        let curl = try XCTUnwrap(m.addSet(try entry("Biceps Curl (Cable)", m)))
        XCTAssertEqual(m.stepped(curl, load: 1).loadValue, 5)
    }

    func testACopiedLoadCanBeTurnedIntoTheExercisesUnit() throws {
        let m = try model()
        m.startWorkout()
        var last = try XCTUnwrap(m.addSet(try entry("Bench Press (Barbell)", m)))
        last.loadValue = 35; last.loadUnit = .lb; last.reps = 10
        var now = last
        now.copyPrescription(from: last, in: .kg)
        XCTAssertEqual(now.loadUnit, .kg); XCTAssertEqual(now.loadValue, 16)
        now.copyPrescription(from: last)
        XCTAssertEqual(now.loadUnit, .lb); XCTAssertEqual(now.loadValue, 35)
    }

    func testSinceTheLastSetCountsFromASetDoneNotFromAnEdit() throws {
        clock = at("2026-11-10 10:00")
        let m = try model()
        m.startWorkout()
        var set = try XCTUnwrap(m.addSet(try entry("Bench Press (Barbell)", m)))
        set.loadValue = 100; set.reps = 8; m.update(set)
        clock.addTimeInterval(60)
        XCTAssertTrue(m.setDone(true, set))
        let done = clock
        clock.addTimeInterval(90)
        var noted = m.activeSets[0]; noted.notes = "felt fine"; m.update(noted)
        XCTAssertEqual(m.lastActivity, done)
    }

    func testARoutineMadeFromAWorkoutKeepsItsTempoAndCanBeFoundByName() throws {
        clock = at("2026-11-10 10:00")
        let m = try model()
        m.startWorkout(title: "Legs")
        var set = try XCTUnwrap(m.addSet(try entry("Squat (Barbell)", m)))
        set.loadValue = 135; set.reps = 5; set.tempo = "3-1-1-0"; m.update(set)
        clock.addTimeInterval(1800); m.finishWorkout()
        let routine = m.routine(from: m.workouts[0])
        XCTAssertEqual(routine.items.first?.tempo, "3-1-1-0")
        m.save(routine)
        XCTAssertEqual(m.routine(named: " legs ")?.id, routine.id)
        XCTAssertNil(m.routine(named: "Arms"))
    }

    func testAMilestoneCanBeTickedForAChosenDay() throws {
        clock = at("2026-11-10 10:00")
        let m = try model()
        let stairs = Milestone(title: "Stairs without the rail")
        m.save(quad("2026-10-01", plan: InjuryPlan(milestones: [stairs])))
        m.setMilestone(stairs.id, done: true, for: m.injuries[0], on: Day("2026-11-07"))
        XCTAssertEqual(m.milestones(for: m.injuries[0])[0].reachedOn, Day("2026-11-07"))
        m.setMilestone(stairs.id, done: true, for: m.injuries[0], on: Day("2026-12-25"))     // not a day to come
        XCTAssertEqual(m.milestones(for: m.injuries[0])[0].reachedOn, Day("2026-11-10"))
    }
}
