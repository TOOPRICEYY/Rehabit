import XCTest
@testable import RehabitCore

/// Progress, records and left-right symmetry, from made-up sessions logged the
/// way the phone logs them. Every expected number is worked out by hand.
final class ProgressTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    lazy var clock = noon("2026-11-17")
    let today = "2026-11-17"

    func noon(_ day: String) -> Date { Day(day)!.start(in: zone).addingTimeInterval(12 * 3600) }

    func makeModel() throws -> AppModel {
        let model = AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
        model.profile = Profile(bodyweightKg: 80, unit: .kg)
        return model
    }

    /// One set as typed: a hold when `hold` is given, reps otherwise. Loads are in kg.
    struct Entry {
        var name: String
        var side: Side = .both
        var load: Double?
        var reps: Double?
        var hold: Double?
        var warmup = false
        var pain: Double?
        /// Left nil to keep the catalogue's.
        var convention: LoadConvention?
    }

    func entry(_ model: AppModel, _ name: String) -> CatalogueExercise {
        model.library.catalogue.first { $0.name == name }
            ?? CatalogueExercise(name: name, pattern: "core", convention: .bodyweight, unilateral: true)
    }

    /// Adds sets to the workout in progress, as the screen would.
    @discardableResult
    func add(_ model: AppModel, _ entries: [Entry]) throws -> [WorkoutSet] {
        try entries.map { e in
            var set = try XCTUnwrap(model.addSet(entry(model, e.name), side: e.side))
            set.kind = e.hold == nil ? .reps : .hold
            set.reps = e.hold == nil ? e.reps : nil
            set.holdSeconds = e.hold
            set.loadValue = e.load
            set.loadUnit = .kg
            set.isWarmup = e.warmup
            set.pain = e.pain
            if let convention = e.convention { set.convention = convention }
            model.update(set)
            return set
        }
    }

    /// A whole session on one day, started and finished at noon.
    @discardableResult
    func log(_ model: AppModel, on day: String, _ entries: [Entry]) throws -> String {
        clock = noon(day)
        model.startWorkout()
        let id = try XCTUnwrap(model.active?.id)
        try add(model, entries)
        model.finishWorkout()
        clock = noon(today)
        return id
    }

    // MARK: One-rep max

    func testTheEstimateCoversOneToTwelveRepsOnly() {
        XCTAssertEqual(OneRepMax.epley(loadKg: 100, reps: 12)!, 140, accuracy: 1e-9)
        XCTAssertNil(OneRepMax.epley(loadKg: 100, reps: 13))
        XCTAssertEqual(OneRepMax.epley(loadKg: 90, reps: 1)!, 93, accuracy: 1e-9)
        XCTAssertNil(OneRepMax.epley(loadKg: 100, reps: 0))
        XCTAssertNil(OneRepMax.epley(loadKg: 0, reps: 5))
        XCTAssertNil(OneRepMax.epley(loadKg: nil, reps: 5))
    }

    func testTheEstimateCountsBodyWeightAndSkipsHolds() throws {
        let model = try makeModel()
        let workout = Workout(zone: zone)
        // A push-up moves 0.64 of 80 kg: 51.2 kg x (1 + 10/30).
        let pushUp = WorkoutSet(workout: workout, position: 0, exercise: "Push-Up", pattern: "push_up",
                                reps: 10, convention: .bodyweight)
        XCTAssertEqual(model.estimatedOneRepMax(pushUp)!, 51.2 * 4 / 3, accuracy: 1e-9)
        // 45 lb is 20.41 kg.
        let pounds = WorkoutSet(workout: workout, position: 1, exercise: "Squat (Barbell)", pattern: "squat",
                                reps: 5, loadValue: 45, loadUnit: .lb)
        XCTAssertEqual(model.estimatedOneRepMax(pounds)!, 45 * 0.45359237 * 7 / 6, accuracy: 1e-9)
        let hold = WorkoutSet(workout: workout, position: 2, exercise: "Wall Sit", pattern: "squat",
                              kind: .hold, holdSeconds: 30, loadValue: 20, loadUnit: .kg)
        XCTAssertNil(model.estimatedOneRepMax(hold))
    }

    // MARK: Sessions

    func testASessionLeavesOutWarmupsAndCountsPerHandTwiceWithBothHands() throws {
        let model = try makeModel()
        let curl = "Biceps Curl (Dumbbell)"
        try log(model, on: "2026-11-10", [
            Entry(name: curl, load: 5, reps: 10, warmup: true, pain: 5),
            Entry(name: curl, load: 12, reps: 10),
            Entry(name: curl, load: 14, reps: 8),
            Entry(name: curl, load: 14, reps: 6, pain: 3),
            Entry(name: "Single-Arm Row (Dumbbell)", side: .left, load: 30, reps: 10),
            Entry(name: "Squat (Barbell)", load: 100, reps: 5),
            Entry(name: "Plank", hold: 60),
            Entry(name: "Plank", hold: 45),
        ])
        let history = model.exerciseHistory("  biceps curl (DUMBBELL) ")
        XCTAssertEqual(history.count, 1)
        let session = try XCTUnwrap(history.first)
        XCTAssertEqual(session.day, Day("2026-11-10"))
        XCTAssertEqual(session.side, .both)
        XCTAssertEqual(session.sets.count, 3)
        // Two dumbbells: 2 x (12x10 + 14x8 + 14x6) = 2 x 316.
        XCTAssertEqual(session.volumeKg, 632, accuracy: 1e-9)
        XCTAssertEqual(session.topSet?.reps, 8)
        XCTAssertEqual(session.topLoadKg, 14)
        XCTAssertEqual(session.bestE1RMKg!, 14 * (1 + 8.0 / 30), accuracy: 1e-9)
        XCTAssertEqual(session.maxPain, 3)                                  // the warm-up's 5 is left out
        XCTAssertNil(session.longestHoldSeconds)

        // One dumbbell on one side counts once; a bar counts once.
        XCTAssertEqual(model.exerciseHistory("Single-Arm Row (Dumbbell)").first?.volumeKg, 300)
        XCTAssertEqual(model.exerciseHistory("Squat (Barbell)").first?.volumeKg, 500)

        let plank = try XCTUnwrap(model.exerciseHistory("Plank").first)
        XCTAssertEqual(plank.volumeKg, 0)
        XCTAssertEqual(plank.longestHoldSeconds, 60)
        XCTAssertNil(plank.topSet)
        XCTAssertNil(plank.bestE1RMKg)
    }

    func testHistoryIsOldestFirstFinishedOnlyAndSkipsWarmupOnlySessions() throws {
        let model = try makeModel()
        let ext = "Single-Leg Extension (Machine)"
        try log(model, on: "2026-11-05", [Entry(name: ext, side: .left, load: 25, reps: 8),
                                          Entry(name: ext, side: .right, load: 30, reps: 8)])
        try log(model, on: "2026-11-01", [Entry(name: ext, side: .left, load: 20, reps: 10)])
        try log(model, on: "2026-11-08", [Entry(name: ext, side: .left, load: 10, reps: 10, warmup: true)])
        model.startWorkout()
        try add(model, [Entry(name: ext, side: .left, load: 40, reps: 5)])   // still in progress
        let history = model.exerciseHistory(ext)
        XCTAssertEqual(history.map(\.day.description), ["2026-11-01", "2026-11-05", "2026-11-05"])
        XCTAssertEqual(history.map(\.side), [.left, .left, .right])
    }

    // MARK: Records

    func testRecordsKeepTheDayTheyWereFirstSetAndATieDoesNotMoveThem() throws {
        let model = try makeModel()
        let ext = "Single-Leg Extension (Machine)"
        try log(model, on: "2026-11-01", [Entry(name: ext, side: .left, load: 20, reps: 10),
                                          Entry(name: ext, side: .left, load: 20, reps: 12)])
        try log(model, on: "2026-11-05", [Entry(name: ext, side: .left, load: 25, reps: 8)])
        try log(model, on: "2026-11-08", [Entry(name: ext, side: .left, load: 25, reps: 8),
                                          Entry(name: ext, side: .left, load: 20, reps: 12)])
        let records = model.records(for: ext, side: .left)
        XCTAssertEqual(records.heaviestLoad?.value, 25)
        XCTAssertEqual(records.heaviestLoad?.day, Day("2026-11-05"))
        // 25 x (1 + 8/30) = 31.67 beats 20 x (1 + 12/30) = 28.
        XCTAssertEqual(records.bestE1RM!.value, 25 * 38 / 30, accuracy: 1e-9)
        XCTAssertEqual(records.bestE1RM?.day, Day("2026-11-05"))
        XCTAssertEqual(records.mostRepsAtLoad.map(\.loadKg), [20, 25])
        XCTAssertEqual(records.mostRepsAtLoad.map(\.value), [12, 8])
        XCTAssertEqual(records.mostRepsAtLoad.map(\.day.description), ["2026-11-01", "2026-11-05"])
        XCTAssertTrue(records.longestHoldAtLoad.isEmpty)
        XCTAssertTrue(model.records(for: ext, side: .right).isEmpty)
    }

    func testASetBreaksOnlyRecordsItBeatsOutright() throws {
        let model = try makeModel()
        let ext = "Single-Leg Extension (Machine)"
        let first = try log(model, on: "2026-11-01", [Entry(name: ext, side: .left, load: 20, reps: 12)])
        let second = try log(model, on: "2026-11-05", [Entry(name: ext, side: .left, load: 25, reps: 8)])
        func only(_ id: String) throws -> WorkoutSet {
            try XCTUnwrap(model.workouts.first { $0.id == id }.flatMap { model.sets(of: $0).first })
        }
        // The first session had nothing to beat; the second is measured against the first only.
        XCTAssertEqual(model.recordsBroken(by: try only(first)), [])
        XCTAssertEqual(model.recordsBroken(by: try only(second)), [.heaviestLoad, .bestE1RM])

        model.startWorkout()
        var set = try add(model, [Entry(name: ext, side: .left, load: 25, reps: 8)])[0]
        XCTAssertEqual(model.recordsBroken(by: set), [])                       // a tie
        set.reps = 9                                                            // 25 x 1.3 = 32.5
        XCTAssertEqual(model.recordsBroken(by: set), [.bestE1RM, .mostRepsAtLoad])
        set.loadValue = 30; set.reps = 1                                        // 30 x 31/30 = 31 < 31.67
        XCTAssertEqual(model.recordsBroken(by: set), [.heaviestLoad])
        set.isWarmup = true
        XCTAssertEqual(model.recordsBroken(by: set), [])
        // The first set ever on the right side has nothing to beat, however heavy.
        let right = try add(model, [Entry(name: ext, side: .right, load: 50, reps: 10)])[0]
        XCTAssertEqual(model.recordsBroken(by: right), [])
    }

    func testHoldRecordsAreKeptPerLoad() throws {
        let model = try makeModel()
        try log(model, on: "2026-11-01", [Entry(name: "Plank", hold: 60)])
        try log(model, on: "2026-11-03", [Entry(name: "Plank", hold: 45), Entry(name: "Plank", load: 10, hold: 30, convention: .bodyweightPlus)])
        let records = model.records(for: "Plank", side: .both)
        XCTAssertEqual(records.longestHoldAtLoad.map(\.loadKg), [nil, 10])
        XCTAssertEqual(records.longestHoldAtLoad.map(\.value), [60, 30])
        XCTAssertNil(records.heaviestLoad)

        model.startWorkout()
        var set = try add(model, [Entry(name: "Plank", hold: 60)])[0]
        XCTAssertEqual(model.recordsBroken(by: set), [])
        set.holdSeconds = 61
        XCTAssertEqual(model.recordsBroken(by: set), [.longestHoldAtLoad])
        set.loadValue = 20; set.convention = .bodyweightPlus                    // never held at 20 kg
        XCTAssertEqual(model.recordsBroken(by: set), [])
    }

    // MARK: Symmetry

    func testSymmetryComparesOneRepMaxesWhenBothSidesLifted() throws {
        let model = try makeModel()
        let ext = "Single-Leg Extension (Machine)"
        try log(model, on: "2026-11-03", [Entry(name: ext, side: .left, load: 20, reps: 10),
                                          Entry(name: ext, side: .right, load: 30, reps: 10)])
        try log(model, on: "2026-11-10", [Entry(name: ext, side: .left, load: 25, reps: 10),
                                          Entry(name: ext, side: .right, load: 30, reps: 10)])
        try log(model, on: "2026-11-12", [Entry(name: ext, side: .left, load: 25, reps: 10)])   // one side only
        try log(model, on: "2026-11-14", [Entry(name: ext, side: .both, load: 50, reps: 10)])
        let points = model.symmetry(exercise: ext)
        XCTAssertEqual(points.map(\.day.description), ["2026-11-03", "2026-11-10"])
        XCTAssertEqual(points[0].measure, .e1RM)
        XCTAssertEqual(points[0].left!, 20 * 4 / 3, accuracy: 1e-9)
        XCTAssertEqual(points[0].right!, 40, accuracy: 1e-9)
        XCTAssertEqual(points[0].ratio(injured: .left)!, 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(points[0].ratio(injured: .right)!, 1.5, accuracy: 1e-9)
        XCTAssertEqual(points[1].ratio(injured: .left)!, 25.0 / 30, accuracy: 1e-9)
        XCTAssertNil(points[1].ratio(injured: .both))
    }

    func testSymmetryFallsBackToHoldsAndNeverMixesMeasures() throws {
        let model = try makeModel()
        let calf = "Single-Leg Calf Raise (Dumbbell)"
        // Loaded holds at different loads: 30 s x 10 kg against 45 s x 20 kg.
        try log(model, on: "2026-11-02", [Entry(name: calf, side: .left, load: 10, hold: 30),
                                          Entry(name: calf, side: .right, load: 20, hold: 45)])
        // A loaded hold against one with no load typed: nothing to compare.
        try log(model, on: "2026-11-04", [Entry(name: calf, side: .left, load: 10, hold: 30),
                                          Entry(name: calf, side: .right, hold: 40)])
        // Lifted on one side, held on the other.
        try log(model, on: "2026-11-06", [Entry(name: calf, side: .left, load: 10, reps: 10),
                                          Entry(name: calf, side: .right, load: 10, hold: 40)])
        // Body-weight holds with no load: seconds against seconds.
        try log(model, on: "2026-11-08", [Entry(name: "Side Plank", side: .left, hold: 30),
                                          Entry(name: "Side Plank", side: .right, hold: 40)])

        let points = model.symmetry(exercise: calf)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].measure, .holdLoad)
        XCTAssertEqual(points[0].left, 300)
        XCTAssertEqual(points[0].right, 900)
        XCTAssertEqual(points[0].ratio(injured: .left)!, 1.0 / 3, accuracy: 1e-9)
        for point in points.dropFirst() {
            XCTAssertNil(point.measure)
            XCTAssertNil(point.left)
            XCTAssertNil(point.ratio(injured: .left))
        }
        // Held at the same load on both sides: the seconds are compared, not load x seconds.
        try log(model, on: "2026-11-09", [Entry(name: "Isometric Leg Extension (Machine)", side: .left, load: 20, hold: 30),
                                          Entry(name: "Isometric Leg Extension (Machine)", side: .right, load: 20, hold: 45)])
        let equal = try XCTUnwrap(model.symmetry(exercise: "Isometric Leg Extension (Machine)").first)
        XCTAssertEqual(equal.measure, .holdSeconds)
        XCTAssertEqual(equal.left, 30); XCTAssertEqual(equal.right, 45)
        let plank = try XCTUnwrap(model.symmetry(exercise: "Side Plank").first)
        XCTAssertEqual(plank.measure, .holdSeconds)
        XCTAssertEqual(plank.ratio(injured: .left)!, 0.75, accuracy: 1e-9)
    }

    func testInjuryRowsListExercisesThatLoadItsTissuesWithTheInjuredSidesRatio() throws {
        let model = try makeModel()
        let ext = "Single-Leg Extension (Machine)", split = "Bulgarian Split Squat (Dumbbell)"
        try log(model, on: "2026-10-01", [Entry(name: ext, side: .left, load: 10, reps: 10, pain: 6),
                                          Entry(name: ext, side: .right, load: 30, reps: 10)])   // before the window
        try log(model, on: "2026-10-25", [Entry(name: ext, side: .left, load: 20, reps: 10),
                                          Entry(name: ext, side: .right, load: 30, reps: 10, pain: 7)])
        try log(model, on: "2026-11-10", [Entry(name: ext, side: .left, load: 25, reps: 10, pain: 2),
                                          Entry(name: ext, side: .right, load: 30, reps: 10),
                                          Entry(name: "Single-Leg Curl (Machine)", side: .left, load: 10, reps: 10),
                                          Entry(name: "Single-Leg Curl (Machine)", side: .right, load: 20, reps: 10),
                                          Entry(name: "Squat (Barbell)", load: 60, reps: 5)])
        try log(model, on: "2026-11-12", [Entry(name: split, side: .left, load: 10, reps: 10),
                                          Entry(name: split, side: .right, load: 12, reps: 10)])
        let injury = Injury(label: "Left quad strain", side: .left, onset: Day("2026-09-20")!, tissues: ["quads"])

        let rows = model.symmetry(for: injury)
        XCTAssertEqual(rows.map(\.exercise), [split, ext])      // the leg curl and the two-sided squat are out
        XCTAssertEqual(rows[0].ratio!, 10.0 / 12, accuracy: 1e-9)
        XCTAssertNil(rows[0].firstRatio)                         // one point is no trend
        XCTAssertNil(rows[0].maxPain)
        XCTAssertEqual(rows[1].latest.day, Day("2026-11-10"))
        XCTAssertEqual(rows[1].ratio!, 25.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(rows[1].firstRatio!, 20.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(rows[1].trend!, 5.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(rows[1].maxPain, 2)                       // not the right side's 7, not October's 6

        // Ten days back reach only the 10 November point.
        let recent = model.symmetry(for: injury, days: 10)
        XCTAssertEqual(recent.map(\.exercise), [split, ext])
        XCTAssertNil(recent[1].firstRatio)

        var both = injury
        both.side = .both
        XCTAssertTrue(model.symmetry(for: both).isEmpty)
    }

    // MARK: Weeks

    func testTheWeekCountsWorkingSetsVolumeAndRegions() throws {
        let model = try makeModel()
        try log(model, on: "2026-11-16", [Entry(name: "Squat (Barbell)", load: 60, reps: 5, warmup: true),
                                          Entry(name: "Squat (Barbell)", load: 100, reps: 5),
                                          Entry(name: "Biceps Curl (Dumbbell)", load: 10, reps: 10)])
        try log(model, on: "2026-11-11", [Entry(name: "Single-Arm Row (Dumbbell)", side: .left, load: 30, reps: 10)])
        try log(model, on: "2026-11-10", [Entry(name: "Squat (Barbell)", load: 100, reps: 5)])

        let week = model.weekSummary()
        XCTAssertEqual(week.start, Day("2026-11-11"))
        XCTAssertEqual(week.end, Day("2026-11-17"))
        XCTAssertEqual(week.sessions, 2)
        XCTAssertEqual(week.workingSets, 3)
        // 100x5 + 2 x 10x10 + 30x10.
        XCTAssertEqual(week.volumeKg, 1000, accuracy: 1e-9)
        // The squat works quads (thigh) and glutes (hip); the row's two prime
        // movers are both in the back, which counts once.
        XCTAssertEqual(week.setsByRegion, ["thigh": 1, "hip": 1, "upper arm": 1, "back": 1])

        let before = model.weekSummary(weeksAgo: 1)
        XCTAssertEqual(before.start, Day("2026-11-04"))
        XCTAssertEqual(before.sessions, 1)
        XCTAssertEqual(before.volumeKg, 500, accuracy: 1e-9)
    }

    func testTheStreakStopsAtTheFirstWeekShortOfSessions() throws {
        let model = try makeModel()
        XCTAssertEqual(model.weeklyStreak(), 0)
        try log(model, on: "2026-11-16", [Entry(name: "Plank", hold: 60)])
        try log(model, on: "2026-11-12", [Entry(name: "Plank", hold: 60)])
        try log(model, on: "2026-11-05", [Entry(name: "Plank", hold: 60)])
        // 28 October to 3 November is empty, so the session on 25 Oct is past a gap.
        try log(model, on: "2026-10-25", [Entry(name: "Plank", hold: 60)])
        XCTAssertEqual(model.weeklyStreak(), 2)
        XCTAssertEqual(model.weeklyStreak(minSessions: 2), 1)

        try log(model, on: "2026-10-30", [Entry(name: "Plank", hold: 60)])
        XCTAssertEqual(model.weeklyStreak(), 4)

        clock = noon("2026-11-25")                               // a week with nothing in it yet
        XCTAssertEqual(model.weeklyStreak(), 0)
        XCTAssertEqual(model.weekSummary().sessions, 0)
    }
}
