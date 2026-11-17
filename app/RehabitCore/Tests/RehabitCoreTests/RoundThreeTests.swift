import XCTest
@testable import RehabitCore

/// Round three: a therapist's limits and milestones, timed holds, tempo,
/// session effort, notes kept with an exercise, the history calendar.
final class RoundThreeTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 0)

    func at(_ text: String) -> Date { GarminClient.localTime(text + ":00", zone: zone)! }
    func model() throws -> AppModel {
        AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
    }
    func entry(_ name: String, _ m: AppModel) throws -> CatalogueExercise {
        try XCTUnwrap(m.library.catalogue.first { $0.name == name }, name)
    }

    /// A finished half-hour session of single-leg extensions ending at the clock.
    @discardableResult
    func session(_ m: AppModel, right: Double, reps: Double = 10, pain: Double? = nil) throws -> Workout {
        let leg = try entry("Single-Leg Extension (Machine)", m)
        clock.addTimeInterval(-1800)
        m.startWorkout()
        var r = try XCTUnwrap(m.addSet(leg, side: .right))
        r.loadValue = right; r.reps = reps; r.pain = pain
        m.update(r)
        clock.addTimeInterval(1800)
        m.finishWorkout()
        return m.workouts[0]
    }

    func quad(_ plan: InjuryPlan?) -> Injury {
        var injury = Injury(label: "Right quad strain", side: .right, onset: Day("2026-05-03")!, tissues: ["quads"])
        injury.plan = plan
        return injury
    }

    // MARK: Limits

    func testSessionsAreCountedAgainstTheLimitsSetForAnInjury() throws {
        clock = at("2026-11-02 08:05")
        let m = try model()
        let injury = quad(InjuryPlan(rule: PainRule(duringMax: 4, settleHours: 24)))
        m.save(injury)
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 1)                 // the level before: 1
        clock = at("2026-11-02 17:00")
        try session(m, right: 20, pain: 5)                                  // over 4 during
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 2)
        clock = at("2026-11-03 08:10")
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 1)                 // settled by the next morning, 15 hours on
        clock = at("2026-11-05 08:05")
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 1)
        clock = at("2026-11-05 17:00")
        try session(m, right: 20, pain: 3)                                  // within 4 during
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 3)
        clock = at("2026-11-06 08:10")
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 3)
        clock = at("2026-11-06 17:30")
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 3)                 // 24 hours on and still 2 above
        clock = at("2026-11-08 17:00")
        try session(m, right: 20)                                           // nothing recorded, nothing answered
        clock = at("2026-11-09 09:00")

        let checks = m.ruleChecks(for: m.injuries[0])
        XCTAssertEqual(checks.map(\.day), [Day("2026-11-08")!, Day("2026-11-05")!, Day("2026-11-02")!])
        XCTAssertEqual(checks.map(\.duringOutcome), [.unknown, .within, .over])
        XCTAssertEqual(checks[2].settleOutcome, .within)
        XCTAssertEqual(checks[1].settleOutcome, .over)
        XCTAssertNotEqual(checks[0].settleOutcome, .over, "a session with no readings after it was called over the time")
        XCTAssertTrue(checks[2].sentence.contains("reached 5, above the limit of 4"), checks[2].sentence)
        XCTAssertTrue(checks[1].isOver); XCTAssertTrue(checks[2].isOver)

        let summary = try XCTUnwrap(m.ruleSummary(for: m.injuries[0]))
        XCTAssertEqual(summary.sessions, 3)
        XCTAssertEqual(summary.duringKnown, 2); XCTAssertEqual(summary.duringOver, 1)
        XCTAssertEqual(summary.settleOver, 1)
        XCTAssertEqual(m.ruleText(for: m.injuries[0]),
                       "Pain during sets no higher than 4, and back to the level before within 24 hours.")

        let text = m.reportText(for: m.injuries[0])
        XCTAssertTrue(text.contains("## Plan"))
        XCTAssertTrue(text.contains("Pain during sets: over the limit in 1 of 2 sessions"), text)
    }

    func testAnInjuryWithNoLimitsHasNothingToCountAgainst() throws {
        clock = at("2026-11-02 17:00")
        let m = try model()
        m.save(quad(nil))
        try session(m, right: 20, pain: 8)
        XCTAssertTrue(m.ruleChecks(for: m.injuries[0]).isEmpty)
        XCTAssertNil(m.ruleSummary(for: m.injuries[0]))
        XCTAssertNil(m.ruleText(for: m.injuries[0]))
        XCTAssertFalse(m.reportText(for: m.injuries[0]).contains("## Plan"))
        // Limits that are not numbers are no limits.
        XCTAssertTrue(PainRule(duringMax: .nan, settleHours: -3).isEmpty)
        XCTAssertNil(InjuryPlan(rule: PainRule()).rule)
    }

    // MARK: Milestones

    func testAMilestoneIsReachedByTheFirstSetThatMeetsIt() throws {
        clock = at("2026-11-02 17:00")
        let m = try model()
        let goal = Milestone(title: "Extension at 40", exercise: "single-leg extension (machine)", loadValue: 40,
                             loadUnit: .lb, count: 10, maxPain: 2)
        let byHand = Milestone(title: "Stairs without the rail")
        m.save(quad(InjuryPlan(milestones: [goal, byHand])))
        try session(m, right: 30, pain: 1)                                  // too light
        clock = at("2026-11-04 17:00")
        try session(m, right: 40)                                           // heavy enough, but no pain recorded
        var progress = m.milestones(for: m.injuries[0])
        XCTAssertNil(progress[0].reachedOn)
        XCTAssertEqual(progress[0].set?.loadValue, 40)
        XCTAssertTrue(progress[0].sentence.contains("no pain recorded"), progress[0].sentence)
        XCTAssertNil(progress[1].reachedOn)

        clock = at("2026-11-06 17:00")
        try session(m, right: 40, pain: 3)                                  // too sore
        clock = at("2026-11-09 17:00")
        try session(m, right: 45, pain: 1.5)                                // met
        clock = at("2026-11-11 17:00")
        try session(m, right: 50, pain: 1)                                  // met again, later
        progress = m.milestones(for: m.injuries[0])
        XCTAssertEqual(progress[0].reachedOn, Day("2026-11-09"))
        XCTAssertEqual(progress[0].set?.loadValue, 45)
        XCTAssertEqual(m.milestoneText(goal), "single-leg extension (machine): 40 lb x 10, pain 2 or less")

        m.setMilestone(byHand.id, done: true, for: m.injuries[0])
        XCTAssertEqual(m.milestones(for: m.injuries[0])[1].reachedOn, Day("2026-11-11"))
        clock = at("2026-11-12 17:00")
        m.setMilestone(byHand.id, done: true, for: m.injuries[0])           // ticking twice keeps the first day
        XCTAssertEqual(m.milestones(for: m.injuries[0])[1].reachedOn, Day("2026-11-11"))
        m.setMilestone(byHand.id, done: false, for: m.injuries[0])
        XCTAssertNil(m.milestones(for: m.injuries[0])[1].reachedOn)
        XCTAssertTrue(m.reportText(for: m.injuries[0]).contains("Milestones reached: 1 of 2."))
    }

    func testAMilestoneIsNotMetByTheOtherSideOrBySetsFromBeforeTheInjury() throws {
        clock = at("2026-04-01 17:00")
        let m = try model()
        try session(m, right: 80)                                           // before the injury began
        clock = at("2026-11-02 17:00")
        let goal = Milestone(title: "Back to 60", exercise: "Single-Leg Extension (Machine)", loadValue: 60, count: 10)
        m.save(quad(InjuryPlan(milestones: [goal])))
        let leg = try entry("Single-Leg Extension (Machine)", m)
        m.startWorkout()
        var left = try XCTUnwrap(m.addSet(leg, side: .left))
        left.loadValue = 70; left.reps = 10
        m.update(left)
        m.finishWorkout()
        let progress = m.milestones(for: m.injuries[0])[0]
        XCTAssertNil(progress.reachedOn)
        XCTAssertNil(progress.set)
        // Kilograms meet a milestone written in pounds.
        clock = at("2026-11-04 17:00")
        m.startWorkout()
        var right = try XCTUnwrap(m.addSet(leg, side: .right))
        right.loadValue = 27.5; right.loadUnit = .kg; right.reps = 10      // 60.6 lb
        m.update(right)
        m.finishWorkout()
        XCTAssertEqual(m.milestones(for: m.injuries[0])[0].reachedOn, Day("2026-11-04"))
    }

    func testAPlanThatCannotBeReadDoesNotCostTheInjury() throws {
        let json = """
        {"id":"i1","label":"Knee","side":"left","onset":"2026-10-01","onsetPrecision":"day","tissues":["quads"],
         "mechanism":"","notes":"","updatedAt":0,
         "plan":{"rule":{"duringMax":"four","settleHours":24},"milestones":[{"title":"Squat","count":-5},17],"nextVisit":"soon"}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let injury = try decoder.decode(Injury.self, from: Data(json.utf8))
        XCTAssertEqual(injury.label, "Knee")
        XCTAssertEqual(injury.plan?.rule?.settleHours, 24)
        XCTAssertNil(injury.plan?.rule?.duringMax)
        XCTAssertNil(injury.plan?.nextVisit)
    }

    // MARK: Holds

    func testATimedHoldSavesWhatWasHeld() throws {
        clock = at("2026-11-02 17:00")
        let m = try model()
        m.startWorkout()
        let plank = try entry("Plank", m)
        var set = try XCTUnwrap(m.addSet(plank))
        set.holdSeconds = 45
        m.update(set)
        XCTAssertTrue(m.startHold(set))
        XCTAssertEqual(m.holdRun?.target, 45)
        clock.addTimeInterval(20)
        XCTAssertEqual(m.holdRun?.remaining(at: clock), 25)
        XCTAssertFalse(m.holdRun?.reachedTarget(at: clock) ?? true)
        clock.addTimeInterval(27)                                           // stopped two seconds late
        XCTAssertTrue(m.stopHold())
        XCTAssertNil(m.holdRun)
        var held = try XCTUnwrap(m.activeSets.first)
        XCTAssertEqual(held.holdSeconds, 45)
        XCTAssertTrue(held.isDone)

        // Stopped early: the seconds really held.
        let second = try XCTUnwrap(m.addSet(plank))
        m.startHold(second)
        clock.addTimeInterval(31.2)
        m.stopHold()
        held = try XCTUnwrap(m.activeSets.first { $0.id == second.id })
        XCTAssertEqual(held.holdSeconds, 31)
        // Stopped at once: not a hold, and not done.
        let third = try XCTUnwrap(m.addSet(plank))
        m.startHold(third)
        XCTAssertFalse(m.stopHold())
        XCTAssertFalse(try XCTUnwrap(m.activeSets.first { $0.id == third.id }).isDone)
        // Cancelled: nothing changes.
        m.startHold(third)
        clock.addTimeInterval(10)
        m.cancelHold()
        XCTAssertNil(m.holdRun)
        XCTAssertFalse(try XCTUnwrap(m.activeSets.first { $0.id == third.id }).isDone)
        XCTAssertFalse(m.stopHold())
    }

    func testARoutineCanPrescribeHoldsAndATempo() throws {
        clock = at("2026-11-02 17:00")
        let m = try model()
        let plank = try entry("Plank", m), bench = try entry("Bench Press (Barbell)", m)
        let routine = Routine(name: "Rehab", items: [
            RoutineItem(exercise: plank.name, pattern: plank.pattern, convention: plank.convention, kind: .hold,
                        rounds: 5, restSeconds: 60, targetCount: 45),
            RoutineItem(exercise: bench.name, pattern: bench.pattern, rounds: 2, targetCount: 8, tempo: "31x0"),
        ])
        m.save(routine)
        XCTAssertEqual(m.routines[0].items[1].tempo, "3-1-X-0")
        XCTAssertTrue(m.startWorkout(from: m.routines[0]))
        let holds = m.activeSets.filter { $0.exercise == plank.name }
        XCTAssertEqual(holds.map(\.holdSeconds), Array(repeating: 45, count: 5))
        let presses = m.activeSets.filter { $0.exercise == bench.name }
        XCTAssertEqual(presses.map(\.reps), [8, 8])
        XCTAssertEqual(presses.map(\.tempo), ["3-1-X-0", "3-1-X-0"])
        XCTAssertEqual(presses[0].timeUnderTension, 32)                    // 8 reps of 4 seconds
        XCTAssertEqual(m.nextUp?.id, holds[0].id)
        m.startHold(holds[0]); clock.addTimeInterval(45); m.stopHold()
        XCTAssertEqual(m.nextUp?.id, holds[1].id)
        XCTAssertEqual(m.rest?.seconds, 60)
    }

    func testTempoIsReadHoweverItIsWritten() {
        XCTAssertEqual(Tempo("3-1-1-0")?.secondsPerRep, 5)
        XCTAssertEqual(Tempo("3/1/1")?.text, "3-1-1-0")
        XCTAssertEqual(Tempo(" 4 0 X 1 ")?.phases, [4, 0, 0, 1])
        XCTAssertEqual(Tempo("2.5-0-2.5-0")?.secondsPerRep, 5)
        XCTAssertNil(Tempo("fast")); XCTAssertNil(Tempo("3-1")); XCTAssertNil(Tempo("0-0-0-0")); XCTAssertNil(Tempo("xxx"))
        XCTAssertNil(Tempo("3-1-1-0-2")); XCTAssertNil(Tempo("99-1-1-0")); XCTAssertNil(Tempo(""))
    }

    // MARK: Effort, notes, calendar

    func testEffortGivesASessionALoadOfItsOwn() throws {
        clock = at("2026-11-02 17:00")
        let m = try model()
        let first = try session(m, right: 20)
        m.setEffort(7.3, for: first)
        XCTAssertEqual(m.workouts[0].effort, 7.5)
        XCTAssertEqual(m.workouts[0].sessionLoad ?? 0, 7.5 * 30, accuracy: 0.001)
        clock = at("2026-11-04 17:00")
        try session(m, right: 20)                                           // no effort given
        let week = m.weekSummary()
        XCTAssertEqual(week.sessions, 2); XCTAssertEqual(week.effortSessions, 1)
        XCTAssertEqual(week.sessionLoad, 225, accuracy: 0.001)
        m.setEffort(40, for: m.workouts[0])
        XCTAssertEqual(m.workouts[0].effort, 10)
        m.setEffort(nil, for: m.workouts[0])
        XCTAssertNil(m.workouts[0].effort)
    }

    func testANoteStaysWithItsExercise() throws {
        let m = try model()
        m.setExerciseNote("  Seat 4, pad at the ankle  ", for: "Leg Extension (Machine)")
        XCTAssertEqual(m.exerciseNote(for: " leg extension (machine)"), "Seat 4, pad at the ankle")
        XCTAssertEqual(m.exerciseNote(for: "Leg Curl (Machine)"), "")
        m.setExerciseNote("   ", for: "Leg Extension (Machine)")
        XCTAssertEqual(m.exerciseNote(for: "Leg Extension (Machine)"), "")
        XCTAssertTrue(m.profile.exerciseNotes.isEmpty)
        // A profile written before notes were kept still reads.
        let old = try JSONDecoder().decode(Profile.self, from: Data(#"{"unit":"kg","dailyCheckIn":false}"#.utf8))
        XCTAssertEqual(old.unit, .kg); XCTAssertTrue(old.exerciseNotes.isEmpty); XCTAssertTrue(old.askEffort)
    }

    func testTheCalendarShowsWhatWasLoggedEachDay() throws {
        clock = at("2026-11-02 08:05")
        let m = try model()
        let injury = quad(nil)
        m.save(injury)
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 2)
        clock = at("2026-11-02 17:00")
        try session(m, right: 20, pain: 3)
        clock = at("2026-11-03 13:00")
        m.logPain([(injury: injury, pain: 6, type: PainType.sharp)], context: "stairs")
        let month = m.calendar(year: 2026, month: 11)
        XCTAssertEqual(month.count, 30)
        XCTAssertEqual(month[0].day, Day("2026-11-01")); XCTAssertTrue(month[0].isEmpty)
        XCTAssertEqual(month[1].workouts.count, 1); XCTAssertEqual(month[1].workingSets, 1)
        XCTAssertEqual(month[1].painHigh, 2); XCTAssertEqual(month[1].setPain, 3)
        XCTAssertEqual(month[2].flares, 1); XCTAssertNil(month[2].painHigh)
        XCTAssertEqual(m.calendar(year: 2028, month: 2).count, 29)
        XCTAssertTrue(m.calendar(year: 2026, month: 13).isEmpty)
        XCTAssertTrue(m.calendar(from: Day("2026-11-05")!, to: Day("2026-11-01")!).isEmpty)
    }
}
