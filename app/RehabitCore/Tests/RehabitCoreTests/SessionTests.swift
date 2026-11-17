import XCTest
@testable import RehabitCore

final class SessionTests: XCTestCase {
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
             warmup: Bool = false) throws -> WorkoutSet {
        var set = try XCTUnwrap(m.addSet(try entry(name, m), side: side))
        set.loadValue = load; set.reps = reps; set.isWarmup = warmup
        m.update(set)
        return set
    }

    /// A finished session a day before the current clock.
    func earlier(_ m: AppModel, _ body: () throws -> Void) rethrows {
        clock.addTimeInterval(-86_400)
        m.startWorkout()
        try body()
        m.finishWorkout()
        clock.addTimeInterval(86_400)
    }

    func pecWeek(_ m: AppModel) -> Double {
        m.tissueWeeks().first { $0.tissue.id == "pec_major" }?.week ?? 0
    }

    func testPlannedSetsAreNotLoadOnceAnySetIsMarkedDone() throws {
        let m = try model()
        m.startWorkout()
        let sets = try (0..<3).map { _ in try add(m, "Bench Press (Barbell)", load: 100) }
        // Nothing marked: the marks are not in use, every set counts and none is unfinished.
        XCTAssertTrue(m.unfinishedSets.isEmpty)
        let all = pecWeek(m)
        XCTAssertGreaterThan(all, 0)

        m.setDone(true, sets[0])
        XCTAssertEqual(m.unfinishedSets.map(\.id), [sets[1].id, sets[2].id])
        XCTAssertEqual(pecWeek(m), all / 3, accuracy: 0.001)
        XCTAssertEqual(m.activeSets[0].completedAt, clock)
        m.setDone(false, sets[0])
        XCTAssertEqual(pecWeek(m), all, accuracy: 0.001)

        m.setDone(true, sets[0]); m.setDone(true, sets[1])
        // "Add set" copies the numbers of the set before it, never that it was done.
        let fourth = try XCTUnwrap(m.addSet(try entry("Bench Press (Barbell)", m)))
        XCTAssertNil(fourth.completedAt); XCTAssertEqual(fourth.loadValue, 100)
        m.finishWorkout(removingUnfinished: true)
        XCTAssertEqual(m.sets(of: m.workouts[0]).map(\.id), [sets[0].id, sets[1].id])
        XCTAssertEqual(pecWeek(m), all * 2 / 3, accuracy: 0.001)
        XCTAssertNil(m.lastError)
    }

    func testFinishingKeepsUnmarkedSetsUnlessAskedToRemoveThem() throws {
        let m = try model()
        m.startWorkout()
        let a = try add(m, "Bench Press (Barbell)", load: 100)
        try add(m, "Bench Press (Barbell)", load: 100)
        m.setDone(true, a)
        m.finishWorkout()
        XCTAssertEqual(m.sets(of: m.workouts[0]).count, 2)
        // A record from before sets could be marked reads as not marked.
        let old = #"{"id":"s","workoutID":"w","workoutDay":"2026-01-01","position":0,"exercise":"Plank","side":"both","kind":"hold","loadUnit":"kg","convention":"bodyweight","isWarmup":false,"notes":"","updatedAt":0}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        XCTAssertNil(try decoder.decode(WorkoutSet.self, from: Data(old.utf8)).completedAt)
    }

    func testRowsLeftBlankAreNotKeptAndASetsPainShowsBesideItsFollowUp() throws {
        let m = try model()
        m.save(Injury(label: "Calf", side: .left, onset: Day("2026-05-01")!, tissues: ["calf"]))
        m.startWorkout()
        var left = try add(m, "Single-Leg Calf Raise (Dumbbell)", side: .left, load: 10)
        left.pain = 3
        m.update(left)
        _ = m.addExercise(try entry("Lateral Raise (Dumbbell)", m), mode: .together)       // added, never filled in
        XCTAssertTrue(m.activeSets[1].isBlank)
        m.finishWorkout()
        XCTAssertEqual(m.sets(of: m.workouts[0]).map(\.exercise), ["Single-Leg Calf Raise (Dumbbell)"])
        XCTAssertEqual(m.weekSummary().workingSets, 1)
        let item = try XCTUnwrap(m.checkInRound.first)
        XCTAssertEqual(item.check.moment, .afterSession)
        XCTAssertEqual(item.sessionPain, 3)                       // shown beside the question
        XCTAssertNil(item.last); XCTAssertNil(item.unchangedValue) // but it is not a reading to copy
        // A workout of nothing but blank rows is not kept at all.
        clock.addTimeInterval(7200)
        m.startWorkout()
        _ = m.addExercise(try entry("Lateral Raise (Dumbbell)", m), mode: .together)
        m.finishWorkout()
        XCTAssertEqual(m.workouts.count, 1); XCTAssertNil(m.active)
    }

    func testRestRunsFromTheLastSetMarkedDone() throws {
        let m = try model()
        m.startWorkout()
        let warm = try add(m, "Bench Press (Barbell)", load: 50, warmup: true)
        let work = try add(m, "Bench Press (Barbell)", load: 100)
        XCTAssertNil(m.rest)
        m.setDone(true, warm)
        XCTAssertNil(m.rest)                                              // no countdown after a warm-up
        clock.addTimeInterval(60)
        m.setDone(true, work)
        var rest = try XCTUnwrap(m.rest)
        XCTAssertEqual(rest.seconds, 120); XCTAssertEqual(rest.endsAt, clock.addingTimeInterval(120))
        clock.addTimeInterval(30)
        XCTAssertEqual(rest.remaining(at: clock), 90)

        m.setRest(45, for: " bench press (barbell) ")
        rest = try XCTUnwrap(m.rest)
        XCTAssertEqual(rest.seconds, 45); XCTAssertEqual(rest.remaining(at: clock), 15)
        m.skipRest()
        XCTAssertNil(m.rest)
        // The next set marked done starts it again.
        clock.addTimeInterval(100)
        let next = try add(m, "Bench Press (Barbell)", load: 100)
        m.setDone(true, next)
        XCTAssertEqual(m.rest?.setID, next.id)
        m.setRest(nil, for: "Bench Press (Barbell)")
        XCTAssertEqual(m.rest?.seconds, 120)
        m.profile.defaultRestSeconds = 0
        XCTAssertNil(m.rest)
        // The setting is kept with the profile.
        let copy = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(m.profile))
        XCTAssertEqual(copy.defaultRestSeconds, 0)
    }

    func testLoadStepIsLearnedFromTheLoadsUsed() throws {
        let m = try model()
        XCTAssertEqual(m.loadStep(for: "Bench Press (Barbell)", unit: .lb), 5)
        XCTAssertEqual(m.loadStep(for: "Bench Press (Barbell)", unit: .kg), 2.5)
        try earlier(m) {
            for load in [100.0, 110, 130] { try add(m, "Leg Press (Machine)", load: load) }       // a 10 lb stack
            for load in [20.0, 60] { try add(m, "Leg Curl (Machine)", load: load) }               // two loads far apart
            for load in [40.0, 42.5] { try add(m, "Biceps Curl (Barbell)", load: load) }          // small plates
            for load in [50.0, 60, 65] { try add(m, "Squat (Barbell)", load: load) }              // not one regular step
        }
        XCTAssertEqual(m.loadStep(for: "Leg Press (Machine)", unit: .lb), 10)
        XCTAssertEqual(m.loadStep(for: "Leg Curl (Machine)", unit: .lb), 5)
        XCTAssertEqual(m.loadStep(for: "Biceps Curl (Barbell)", unit: .lb), 2.5)
        XCTAssertEqual(m.loadStep(for: "Squat (Barbell)", unit: .lb), 5)

        m.startWorkout()
        let set = try add(m, "Leg Press (Machine)", load: 130)
        XCTAssertEqual(m.stepped(set, load: 1).loadValue, 140)
        XCTAssertEqual(m.stepped(set, load: -20).loadValue, 0)
        XCTAssertEqual(m.stepped(set, count: -3).reps, 7)
        var hold = set; hold.kind = .hold; hold.holdSeconds = 30
        XCTAssertEqual(m.stepped(hold, count: 2).holdSeconds, 40)
    }

    func testWarmUpsGoFirstAtHalfOfEachSidesOwnLoad() throws {
        let m = try model()
        m.startWorkout()
        try add(m, "Bench Press (Barbell)", load: 135)
        try add(m, "Single-Leg Extension (Machine)", side: .left, load: 20)
        try add(m, "Single-Leg Extension (Machine)", side: .right, load: 60)
        m.setLinked(false, for: "Single-Leg Extension (Machine)")
        let warm = m.addWarmupRound(to: m.block("Single-Leg Extension (Machine)"))
        XCTAssertEqual(warm.map(\.loadValue), [10, 30])
        XCTAssertTrue(warm.allSatisfy { $0.isWarmup && !$0.isDone })
        let rounds = m.block("Single-Leg Extension (Machine)").rounds
        XCTAssertEqual(rounds.map(\.isWarmup), [true, false])
        XCTAssertEqual(m.activeSets.map(\.exercise).first, "Bench Press (Barbell)")       // the bench keeps its place
        XCTAssertEqual(m.activeSets.map(\.position), Array(0..<5))

        // The round after a warm-up is a working round with the working numbers.
        let next = m.addRound(to: m.block("Single-Leg Extension (Machine)"))
        XCTAssertEqual(next.map(\.loadValue), [20, 60])
        XCTAssertTrue(next.allSatisfy { !$0.isWarmup })
    }

    func testTheSetAfterALoneWarmUpTakesLastSessionsWorkingNumbers() throws {
        let m = try model()
        try earlier(m) {
            try add(m, "Bench Press (Barbell)", load: 45, reps: 10, warmup: true)
            try add(m, "Bench Press (Barbell)", load: 135, reps: 8)
        }
        m.startWorkout()
        var first = try XCTUnwrap(m.addSet(try entry("Bench Press (Barbell)", m)))
        XCTAssertEqual(first.loadValue, 135)                                       // prefilled from the working set
        first.isWarmup = true; first.loadValue = 65
        m.update(first)
        let second = try XCTUnwrap(m.addSet(try entry("Bench Press (Barbell)", m)))
        XCTAssertFalse(second.isWarmup)
        XCTAssertEqual(second.loadValue, 135); XCTAssertEqual(second.reps, 8)
    }

    func testChangingTheUnitKeepsTheWeightOrTheNumbers() throws {
        let m = try model()
        m.startWorkout()
        try add(m, "Bench Press (Barbell)", load: 100)
        try add(m, "Bench Press (Barbell)", load: 45)
        m.setUnit(.kg, for: "Bench Press (Barbell)")
        XCTAssertEqual(m.activeSets[0].loadValue ?? 0, 45.359, accuracy: 0.001)
        XCTAssertEqual(m.activeSets[1].loadValue ?? 0, 20.412, accuracy: 0.001)
        XCTAssertTrue(m.activeSets.allSatisfy { $0.loadUnit == .kg })
        m.setUnit(.lb, for: "Bench Press (Barbell)")                      // and back: the numbers first typed
        XCTAssertEqual(m.activeSets.map(\.loadValue), [100, 45])
        m.setUnit(.kg, for: "Bench Press (Barbell)", converting: false)   // "they were kilograms all along"
        XCTAssertEqual(m.activeSets.map(\.loadValue), [100, 45])
        XCTAssertTrue(m.activeSets.allSatisfy { $0.loadUnit == .kg })
    }

    func testLinkedSidesSurviveARelaunch() throws {
        let store = try Store(path: ":memory:")
        let m = try model(store)
        m.startWorkout()
        try add(m, "Single-Leg Extension (Machine)", side: .left, load: 20)
        XCTAssertTrue(m.isLinked("Single-Leg Extension (Machine)"))
        m.setLinked(false, for: "Single-Leg Extension (Machine)")
        let again = try model(store)
        XCTAssertFalse(again.isLinked("Single-Leg Extension (Machine)"))
        again.removeExercise("Single-Leg Extension (Machine)")
        XCTAssertNil(again.active?.linkOverrides)
        XCTAssertNil(again.lastError)
    }

    func testAFirstSetOnOneSideStartsFromTheOtherUnlessThatSideIsInjured() throws {
        let m = try model()
        try earlier(m) { try add(m, "Single-Leg Extension (Machine)", side: .left, load: 60, reps: 12) }
        m.startWorkout()
        let right = try XCTUnwrap(m.addSet(try entry("Single-Leg Extension (Machine)", m), side: .right))
        XCTAssertEqual(right.loadValue, 60); XCTAssertEqual(right.reps, 12)
        m.removeSet(id: right.id)

        m.save(Injury(label: "Quad", side: .right, onset: Day("2026-05-01")!, tissues: ["quads"]))
        let injured = try XCTUnwrap(m.addSet(try entry("Single-Leg Extension (Machine)", m), side: .right))
        XCTAssertNil(injured.loadValue); XCTAssertNil(injured.reps)        // the healthy side's load is no starting point
        let both = try XCTUnwrap(m.addSet(try entry("Leg Extension (Machine)", m)))
        XCTAssertNil(both.loadValue)
    }

    func testHoldsStartAsHoldsAndTheTimerWritesTheSeconds() throws {
        let m = try model()
        m.startWorkout()
        let wallSit = try XCTUnwrap(m.addSet(try entry("Wall Sit", m)))
        XCTAssertEqual(wallSit.kind, .hold)
        m.finishHold(wallSit, seconds: 44.8)
        XCTAssertEqual(m.activeSets[0].holdSeconds, 45)
        XCTAssertTrue(m.activeSets[0].isDone)
        XCTAssertNotNil(m.rest)
        XCTAssertEqual(try entry("Bench Press (Barbell)", m).kind, .reps)
        XCTAssertEqual(m.library.catalogue.filter { $0.kind == .hold }.count, 15)
    }

    func testImportedNamesMapByTheSharedRules() {
        XCTAssertFalse(Library.standard.matchers.isEmpty)
        let expected = ["Hanging Leg Raise": "core", "Nordic Hamstring Curl": "leg_curl", "Barbell Hip Thrust": "bridge",
                        "Bulgarian Split Squat": "lunge", "Wrist Curl": "wrist_curl", "Lateral Raise (Dumbbell)": "raise_lateral",
                        "Hip Abduction (Machine)": "hip_abduction", "Triceps Kickback": "triceps_extension",
                        "Seated Cable Row - V Grip (Cable)": "row"]
        for (name, pattern) in expected { XCTAssertEqual(ExerciseMatcher.pattern(for: name), pattern, name) }
        // Every name in the picker maps to its own pattern by the rules too.
        for entry in Library.standard.catalogue {
            XCTAssertEqual(ExerciseMatcher.pattern(for: entry.name), entry.pattern, entry.name)
        }
        XCTAssertEqual(ExerciseMatcher.entry(for: "Isometric Quad Squeeze", in: .standard).entry.kind, .hold)
    }
}
