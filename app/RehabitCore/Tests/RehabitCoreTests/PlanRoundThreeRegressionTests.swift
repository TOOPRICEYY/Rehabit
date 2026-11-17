import XCTest
@testable import RehabitCore

/// Defects found in round three's plan code: limits, milestones and the report's "## Plan" section.
/// Every test here fails against the code as it stands; all data is made up.
final class PlanRoundThreeRegressionTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 0)
    let legName = "Single-Leg Extension (Machine)"

    func at(_ text: String) -> Date { GarminClient.localTime(text + ":00", zone: zone)! }
    func model() throws -> AppModel {
        AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
    }
    func quad(_ plan: InjuryPlan?) -> Injury {
        var injury = Injury(id: "inj", label: "Right quad strain", side: .right, onset: Day("2026-05-03")!,
                            tissues: ["quads"], updatedAt: Date(timeIntervalSince1970: 1_000))
        injury.plan = plan
        return injury
    }
    /// A finished workout with a chosen id, so the order of ids can be set against the order of times.
    func workout(_ id: String, _ start: String, _ end: String) -> Workout {
        Workout(id: id, title: id, start: at(start), end: at(end), zone: zone)
    }
    func extensionSet(_ m: AppModel, _ w: Workout, position: Int = 0, load: Double = 20, reps: Double = 10,
                      pain: Double? = nil) throws -> WorkoutSet {
        let pattern = try XCTUnwrap(m.library.catalogue.first { $0.name == legName }).pattern
        return WorkoutSet(id: "\(w.id)-\(position)", workout: w, position: position, exercise: legName, pattern: pattern,
                          side: .right, reps: reps, loadValue: load, pain: pain, updatedAt: w.start)
    }
    /// Records brought in the way another device's export is.
    func bringIn(_ m: AppModel, workouts: [Workout] = [], sets: [WorkoutSet] = [], injuries: [Injury] = []) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = Stamp.encoding
        let data = try encoder.encode(Snapshot(exportedAt: clock, profile: Profile(), workouts: workouts, sets: sets,
                                               injuries: injuries, painChecks: [], dailyMetrics: [], tombstones: []))
        _ = m.merge(data)
        XCTAssertNil(m.lastError)
    }

    // Defect: ruleChecks sorts by (day, workoutID), so two sessions on one day come in id order, not newest first.
    func testTwoSessionsOnOneDayAreListedNewestFirst() throws {
        clock = at("2026-11-10 20:00")
        let m = try model()
        let morning = workout("zzz-morning", "2026-11-10 07:00", "2026-11-10 08:00")
        let evening = workout("aaa-evening", "2026-11-10 17:00", "2026-11-10 18:00")
        try bringIn(m, workouts: [morning, evening],
                    sets: [try extensionSet(m, morning, pain: 2), try extensionSet(m, evening, pain: 3)],
                    injuries: [quad(InjuryPlan(rule: PainRule(duringMax: 4)))])
        XCTAssertEqual(m.ruleChecks(for: m.injuries[0]).map(\.workoutID), [evening.id, morning.id])
    }

    // Defect: InjuryPlan.init(from:) throws when "plan" is not an object, so the whole injury becomes unreadable.
    func testAPlanThatIsNotAnObjectDoesNotCostTheInjury() throws {
        clock = at("2026-11-10 20:00")
        let m = try model()
        let json = """
        {"schemaVersion":1,"exportedAt":"2026-11-10T00:00:00Z","workouts":[],"sets":[],"painChecks":[],
         "dailyMetrics":[],"tombstones":[],
         "injuries":[{"id":"i1","label":"Knee","side":"left","onset":"2026-10-01","onsetPrecision":"day",
                      "tissues":["quads"],"mechanism":"","notes":"","updatedAt":"2026-11-01T00:00:00Z",
                      "plan":"see the physio's sheet"}]}
        """
        _ = m.merge(Data(json.utf8))
        XCTAssertEqual(m.injuries.map(\.label), ["Knee"], "the injury was lost to a plan it could not read")
        XCTAssertEqual(m.unreadableCount, 0)
    }

    // Defect: milestones decode as one [Milestone], so one unreadable entry drops every readable milestone with it.
    func testOneUnreadableMilestoneDoesNotCostTheOthers() throws {
        let json = #"{"milestones":[{"id":"m1","title":"Stairs without the rail"},17],"setBy":"Dana, physio"}"#
        let plan = try JSONDecoder().decode(InjuryPlan.self, from: Data(json.utf8))
        XCTAssertEqual(plan.setBy, "Dana, physio")
        XCTAssertEqual(plan.milestones.map(\.title), ["Stairs without the rail"])
    }

    // Defect: milestone ids are not kept unique, and setMilestone ticks the first match, so the second can never be ticked.
    func testEachOfTwoMilestonesWithTheSameIdCanBeTicked() throws {
        clock = at("2026-11-10 20:00")
        let m = try model()
        let json = #"{"milestones":[{"id":"x","title":"Stairs"},{"id":"x","title":"Jog 5 minutes"}]}"#
        var injury = quad(nil)
        injury.plan = try JSONDecoder().decode(InjuryPlan.self, from: Data(json.utf8))
        m.save(injury)
        let jog = m.milestones(for: m.injuries[0])[1]
        m.setMilestone(jog.id, done: true, for: m.injuries[0])
        XCTAssertEqual(m.milestones(for: m.injuries[0]).map(\.isReached), [false, true])
    }

    // Defect: Milestone keeps any finite load or count, and AppModel.plain's Int(...) traps on one like 1e300 in milestoneText.
    func testAMilestoneLoadOrCountTooLargeToBeRealIsDroppedOrClamped() throws {
        let typed = Milestone(title: "Squat", exercise: "Squat", loadValue: 1e300, count: 1e300)
        let read = try JSONDecoder().decode(Milestone.self, from: Data(
            #"{"id":"m","title":"Squat","exercise":"Squat","loadValue":1e300,"count":1e300}"#.utf8))
        for milestone in [typed, read] {
            XCTAssertTrue(milestone.loadValue.map { $0 <= 100_000 } ?? true, "\(String(describing: milestone.loadValue))")
            XCTAssertTrue(milestone.count.map { $0 <= 100_000 } ?? true, "\(String(describing: milestone.count))")
        }
    }

    // Defect: reportText shows a period of max(7, days) but the Plan section counts ruleSummary(days: days), so the two disagree.
    func testThePlanSectionCountsTheSamePeriodTheReportShows() throws {
        clock = at("2026-11-10 20:00")
        let m = try model()
        let session = workout("w1", "2026-11-05 17:00", "2026-11-05 18:00")
        try bringIn(m, workouts: [session], sets: [try extensionSet(m, session, pain: 5)],
                    injuries: [quad(InjuryPlan(rule: PainRule(duringMax: 4)))])
        let text = m.reportText(for: m.injuries[0], days: 3)
        XCTAssertTrue(text.contains("Period: Nov 4, 2026 to Nov 10, 2026 (7 days)."), text)
        XCTAssertTrue(text.contains("- Sessions that loaded it: 1."), text)
        XCTAssertTrue(text.contains("Pain during sets: over the limit in 1 of 1 session"), text)
    }

    // Defect: a milestone's sentence ("<exercise> has not been logged ...") goes into the report without plain(), so a typed newline starts a heading.
    func testATypedExerciseNameCannotStartAHeadingInTheReport() throws {
        clock = at("2026-11-10 20:00")
        let m = try model()
        m.save(quad(InjuryPlan(milestones: [Milestone(title: "Wall sit", exercise: "Wall sit\n## Discharged")])))
        let text = m.reportText(for: m.injuries[0])
        let headings = text.split(separator: "\n").filter { $0.hasPrefix("#") }.map(String.init)
        XCTAssertFalse(headings.contains { $0.contains("Discharged") }, headings.joined(separator: " / "))
    }

    // Defect: hours and reps are always written plural ("1 hours", "1 reps") in ruleText, milestoneText and the settle sentence.
    func testOneHourAndOneRepAreSingular() throws {
        let m = try model()
        let rule = try XCTUnwrap(m.ruleText(for: quad(InjuryPlan(rule: PainRule(settleHours: 1)))))
        XCTAssertFalse(rule.contains("1 hours"), rule)
        let goal = m.milestoneText(Milestone(title: "One clean rep", exercise: legName, count: 1))
        XCTAssertFalse(goal.contains("1 reps"), goal)
    }

    // Defect: milestone candidates sort by (workoutDay, position), so a later session's low-position set beats an earlier one the same day.
    func testTheSetThatFirstMetAMilestoneIsTheEarliestOfItsDay() throws {
        clock = at("2026-11-10 20:00")
        let m = try model()
        let morning = workout("a", "2026-11-10 07:00", "2026-11-10 08:00")
        let evening = workout("b", "2026-11-10 17:00", "2026-11-10 18:00")
        var sets = try (0..<3).map { try extensionSet(m, morning, position: $0, load: 10) }
        sets.append(try extensionSet(m, morning, position: 3, load: 40))          // met here first
        sets.append(try extensionSet(m, evening, position: 0, load: 50))          // met again that evening
        try bringIn(m, workouts: [morning, evening], sets: sets,
                    injuries: [quad(InjuryPlan(milestones: [Milestone(title: "Extension at 40", exercise: legName,
                                                                      loadValue: 40)]))])
        let progress = m.milestones(for: m.injuries[0])[0]
        XCTAssertEqual(progress.reachedOn, Day("2026-11-10"))
        XCTAssertEqual(progress.set?.workoutID, morning.id)
        XCTAssertEqual(progress.set?.loadValue, 40)
    }
}
