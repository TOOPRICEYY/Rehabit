import XCTest
@testable import RehabitCore

private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

final class DayTests: XCTestCase {
    func testRoundTripAndArithmetic() {
        XCTAssertEqual(Day("1970-01-01")?.number, 0)
        XCTAssertEqual(Day("2024-02-29")?.adding(1).description, "2024-03-01")
        XCTAssertEqual(Day("2026-11-16")!.days(since: Day("2025-11-16")!), 365)
        for n in stride(from: -135_000, through: 160_000, by: 97) {
            XCTAssertEqual(Day(Day(number: n).description)?.number, n)
        }
        XCTAssertNil(Day("yesterday"))
    }

    func testDayFollowsTheLocalClockNotUTC() {
        let lateEvening = Date(timeIntervalSince1970: 1_763_350_200)   // 2025-11-17 03:30 UTC
        XCTAssertEqual(Day(lateEvening, in: TimeZone(identifier: "America/Detroit")!).description, "2025-11-16")
        XCTAssertEqual(Day(lateEvening, in: TimeZone(identifier: "UTC")!).description, "2025-11-17")
    }
}

/// The phone must compute the same doses as the service. The fixture is written
/// by the service from a made-up history (`rehabit export-shared`).
final class LedgerParityTests: XCTestCase {
    struct Vectors: Decodable {
        struct VSet: Decodable {
            let day: Day, exercise: String, pattern: String?, side: Side, kind: SetKind
            let reps: Double?, holdSeconds: Double?, loadKg: Double?
        }
        struct VDay: Decodable {
            let day: Day, tissue: String, side: Side
            let dose: Double, sets: Double, reps: Double, acute: Double, chronic: Double
        }
        let sets: [VSet], tissueDays: [VDay]
    }

    func testDosesMatchTheService() throws {
        let vectors = try JSONDecoder().decode(Vectors.self, from: fixture("ledger"))
        let sets = vectors.sets.map {
            LedgerSet(day: $0.day, exercise: $0.exercise, pattern: $0.pattern, side: $0.side, kind: $0.kind,
                      reps: $0.reps, holdSeconds: $0.holdSeconds, loadKg: $0.loadKg)
        }
        let mine = Ledger().tissueDays(sets)
        var byKey: [String: TissueDay] = [:]
        for d in mine { byKey["\(d.day)|\(d.tissue)|\(d.side.rawValue)"] = d }
        XCTAssertGreaterThan(vectors.tissueDays.count, 50)
        for want in vectors.tissueDays {
            let got = try XCTUnwrap(byKey["\(want.day)|\(want.tissue)|\(want.side.rawValue)"], "\(want.day) \(want.tissue)")
            XCTAssertEqual(got.dose, want.dose, accuracy: 0.001, "\(want.day) \(want.tissue) dose")
            XCTAssertEqual(got.sets, want.sets, accuracy: 0.001)
            XCTAssertEqual(got.reps, want.reps, accuracy: 0.001)
            XCTAssertEqual(got.acute, want.acute, accuracy: 0.0001, "\(want.day) \(want.tissue) acute")
            XCTAssertEqual(got.chronic, want.chronic, accuracy: 0.0001)
        }
        // And nothing extra: every loaded day of mine is in the service's list.
        let wanted = Set(vectors.tissueDays.map { "\($0.day)|\($0.tissue)|\($0.side.rawValue)" })
        for d in mine where d.dose > 0 {
            XCTAssertTrue(wanted.contains("\(d.day)|\(d.tissue)|\(d.side.rawValue)"), "\(d.day) \(d.tissue)")
        }
    }

    func testLoadConventions() {
        let ledger = Ledger()
        let profile = Profile(bodyweightKg: 70, unit: .lb)
        let workout = Workout()
        var set = WorkoutSet(workout: workout, position: 0, exercise: "Pull-Up", pattern: "pull_up",
                             loadValue: nil, convention: .bodyweight)
        XCTAssertEqual(ledger.loadKg(set, profile: profile)!, 70, accuracy: 0.001)
        set.convention = .bodyweightPlus
        set.loadValue = 10
        set.loadUnit = .kg
        XCTAssertEqual(ledger.loadKg(set, profile: profile)!, 80, accuracy: 0.001)
        set.convention = .total
        set.loadUnit = .lb
        set.loadValue = 100
        XCTAssertEqual(ledger.loadKg(set, profile: profile)!, 45.359, accuracy: 0.001)
        set.convention = .bodyweight
        XCTAssertNil(ledger.loadKg(set, profile: Profile()))      // unknown body weight stays unknown
    }
}

final class LibraryTests: XCTestCase {
    func testLibraryIsConsistent() {
        let library = Library.standard
        XCTAssertGreaterThan(library.catalogue.count, 40)
        let tissues = Set(library.tissues.map(\.id))
        for pattern in library.patterns {
            for link in pattern.links { XCTAssertTrue(tissues.contains(link.tissue)) }
        }
        for entry in library.catalogue { XCTAssertNotNil(library.pattern(entry.pattern), entry.name) }
        XCTAssertEqual(library.search("bench dumb").map(\.name).first, "Bench Press (Dumbbell)")
    }
}

final class AdvisorTests: XCTestCase {
    let start = Day("2025-01-06")!

    func set(_ offset: Int, _ load: Double, exercise: String = "Bench Press (Dumbbell)",
             pattern: String = "press_horizontal", side: Side = .both) -> LedgerSet {
        LedgerSet(day: start.adding(offset), exercise: exercise, pattern: pattern, side: side, kind: .reps,
                  reps: 10, holdSeconds: nil, loadKg: load)
    }

    func testJumpLayoffReEntryDensityAndInjury() {
        let advisor = Advisor()
        let history = [set(0, 20), set(3, 20)]
        XCTAssertEqual(advisor.advice(for: set(5, 21), history: history).map(\.kind), [])
        XCTAssertEqual(advisor.advice(for: set(5, 24), history: history).map(\.kind), [.intensityJump])
        XCTAssertEqual(Set(advisor.advice(for: set(4, 20), history: history).map(\.kind)), [.density])
        XCTAssertEqual(Set(advisor.advice(for: set(12, 20), history: history).map(\.kind)), [.layoff])
        let back = Set(advisor.advice(for: set(40, 20), history: history).map(\.kind))
        XCTAssertTrue(back.isSuperset(of: [.layoff, .reEntry]))
        let pec = Injury(label: "Left pec strain", side: .left, onset: start, tissues: ["pec_major"])
        let advice = advisor.advice(for: set(5, 20), history: history, injuries: [pec])
        XCTAssertEqual(advice.filter { $0.kind == .injuredTissue }.count, 1)
        XCTAssertTrue(advice[0].detail.contains("left"))
        // The other side's exercise does not touch the injured side.
        let right = set(5, 20, exercise: "Single-Arm Bench Press (Dumbbell)", side: .right)
        XCTAssertTrue(advisor.advice(for: right, history: history, injuries: [pec]).allSatisfy { $0.kind != .injuredTissue })
    }
}

final class StoreTests: XCTestCase {
    func testSaveFindDeleteAndTombstone() throws {
        let store = try Store(path: ":memory:")
        let workout = Workout(title: "Push")
        try store.save(workout)
        let set = WorkoutSet(workout: workout, position: 0, exercise: "Push-Up", pattern: "push_up", reps: 12,
                             pain: 2.5, painType: .pulling)
        try store.save(set)
        XCTAssertEqual(try store.all(WorkoutSet.self, parent: workout.id).first?.pain, 2.5)
        XCTAssertEqual(try store.find(Workout.self, id: workout.id)?.title, "Push")
        try store.deleteWorkout(id: workout.id)
        XCTAssertTrue(try store.all(Workout.self).isEmpty)
        XCTAssertTrue(try store.all(WorkoutSet.self).isEmpty)
        XCTAssertEqual(try store.snapshot().tombstones.count, 2)
    }

    func testMergeTakesTheNewerChangeIncludingADeletion() throws {
        let phone = try Store(path: ":memory:"), tablet = try Store(path: ":memory:")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var workout = Workout(title: "Legs", start: t0)
        let other = Workout(title: "Arms", start: t0)
        try phone.save(workout)
        try phone.save(other)
        try tablet.merge(try phone.snapshot())
        XCTAssertEqual(try tablet.all(Workout.self).count, 2)

        workout.title = "Legs and calves"
        workout.updatedAt = t0.addingTimeInterval(60)
        try tablet.save(workout)                                         // edited on the tablet
        try phone.delete(Workout.self, id: other.id, at: t0.addingTimeInterval(90))   // deleted on the phone

        // Through JSON, as it would travel.
        try phone.merge(Store.decodeSnapshot(try tablet.snapshotJSON()))
        try tablet.merge(Store.decodeSnapshot(try phone.snapshotJSON()))
        for store in [phone, tablet] {
            XCTAssertEqual(try store.all(Workout.self).map(\.title), ["Legs and calves"])
        }
        // An older copy arriving late does not bring the deleted record back.
        var stale = other
        stale.updatedAt = t0.addingTimeInterval(30)
        let old = Snapshot(exportedAt: t0, profile: Profile(), workouts: [stale], sets: [], injuries: [],
                           painChecks: [], dailyMetrics: [], tombstones: [])
        XCTAssertEqual(try phone.merge(old), 0)
    }

    func testMissingMetricStaysMissing() throws {
        let store = try Store(path: ":memory:")
        try store.save([DailyMetric(day: Day("2025-03-01")!, metric: MetricName.hrv, value: 62, source: "test")])
        XCTAssertEqual(try store.dailyMetrics(MetricName.hrv).count, 1)
        XCTAssertTrue(try store.dailyMetrics(MetricName.steps).isEmpty)
    }
}

final class PainScheduleTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!

    func date(_ text: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: text)!
    }

    func testChecksAfterAnAfternoonSession() {
        let schedule = PainSchedule(zone: zone)
        let end = date("2025-11-17T20:00:00Z")                           // 3 PM local
        let workout = Workout(start: end.addingTimeInterval(-3600), zone: zone)
        let injury = Injury(label: "Right quad", side: .right, onset: Day("2025-11-01")!, tissues: ["quads"])
        let checks = schedule.checks(for: injury, workout: workout, endedAt: end)
        XCTAssertEqual(checks.map(\.moment), [.afterSession, .evening, .nextMorning, .hours24, .hours48])
        XCTAssertEqual(checks[1].dueAt, date("2025-11-18T02:00:00Z"))   // 9 PM local, same day
        XCTAssertEqual(checks[2].dueAt, date("2025-11-18T13:00:00Z"))   // 8 AM local
        XCTAssertEqual(checks[2].dueDay.description, "2025-11-18")
        XCTAssertTrue(checks.allSatisfy { $0.pain == nil && !$0.isAnswered })
    }

    func testALateSessionSkipsTheEveningCheck() {
        let schedule = PainSchedule(zone: zone)
        let end = date("2025-11-18T01:00:00Z")                           // 8 PM local
        let workout = Workout(start: end, zone: zone)
        let injury = Injury(label: "x", side: .left, onset: Day("2025-11-01")!, tissues: ["calf"])
        XCTAssertFalse(schedule.checks(for: injury, workout: workout, endedAt: end).contains { $0.moment == .evening })
    }

    func testOnlyInjuriesTheSessionLoadedAreAsked() {
        let schedule = PainSchedule(zone: zone)
        let workout = Workout()
        let sets = [WorkoutSet(workout: workout, position: 0, exercise: "Single-Leg Extension (Machine)",
                               pattern: "leg_extension", side: .right, reps: 10)]
        let quadR = Injury(label: "Right quad", side: .right, onset: Day("2025-11-01")!, tissues: ["quads"])
        let quadL = Injury(label: "Left quad", side: .left, onset: Day("2025-11-01")!, tissues: ["quads"])
        let pec = Injury(label: "Left pec", side: .left, onset: Day("2025-11-01")!, tissues: ["pec_major"])
        var healed = quadR
        healed.id = "healed"
        healed.resolvedOn = Day("2025-11-10")
        XCTAssertEqual(schedule.injuriesLoaded(by: sets, injuries: [quadR, quadL, pec, healed]).map(\.label), ["Right quad"])
    }

    func testSettling() {
        let end = date("2025-11-17T20:00:00Z")
        func check(_ hours: Double, _ pain: Double?) -> PainCheck {
            var c = PainCheck(injuryID: "i", workoutID: "w", moment: .evening, dueAt: end.addingTimeInterval(hours * 3600))
            c.pain = pain
            c.answeredAt = pain == nil ? nil : c.dueAt
            return c
        }
        let settled = SettlingSummary(checks: [check(0, 3), check(6, 4), check(17, nil), check(24, 1.5), check(48, 1)],
                                      baseline: 1, sessionEnd: end)
        XCTAssertEqual(settled.peak, 4)
        XCTAssertEqual(settled.hoursToSettle, 24)
        XCTAssertEqual(settled.answered, 4)
        XCTAssertEqual(settled.asked, 5)
        let not = SettlingSummary(checks: [check(0, 3), check(24, 3)], baseline: 1, sessionEnd: end)
        XCTAssertNil(not.hoursToSettle)
    }
}

final class AppModelTests: XCTestCase {
    var clock = Date(timeIntervalSince1970: 1_763_400_000)               // 2025-11-17 17:20 UTC
    let zone = TimeZone(identifier: "America/Detroit")!

    func makeModel() throws -> AppModel {
        AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
    }

    func testAWorkoutFromStartToPainChecks() throws {
        let model = try makeModel()
        model.profile = Profile(bodyweightKg: 72, unit: .lb)
        model.save(Injury(label: "Right quad strain", side: .right, onset: Day("2025-11-01")!, tissues: ["quads"]))
        let extension_ = try XCTUnwrap(model.library.search("single-leg extension").first)

        model.startWorkout(title: "Rehab")
        var first = try XCTUnwrap(model.addSet(extension_))
        XCTAssertEqual(first.side, .right)                              // defaults to the injured side
        first.loadValue = 30; first.reps = 12; first.pain = 2
        model.update(first)
        let second = try XCTUnwrap(model.addSet(extension_))
        XCTAssertEqual(second.loadValue, 30)                            // copies the set before it
        XCTAssertNil(second.pain)                                       // but never its pain
        XCTAssertTrue(model.advice(for: second).contains { $0.kind == .injuredTissue })

        clock.addTimeInterval(1800)
        let dueNow = model.finishWorkout()
        XCTAssertEqual(dueNow.map(\.moment), [.afterSession])
        XCTAssertNil(model.active)
        XCTAssertEqual(model.workouts.count, 1)
        XCTAssertEqual(model.dueChecks.count, 1)
        XCTAssertEqual(model.upcomingChecks.count, 4)

        model.answer(dueNow[0], pain: 2.7, type: .ache)
        XCTAssertEqual(model.painHistory(for: model.injuries[0]).first?.pain, 2.5)
        XCTAssertTrue(model.dueChecks.isEmpty)

        // Next session: the first set is prefilled from last time, and a jump is named.
        clock.addTimeInterval(3 * 86_400)
        XCTAssertEqual(model.dueChecks.count, 4)                         // the delayed ones came due
        model.startWorkout()
        var again = try XCTUnwrap(model.addSet(extension_))
        XCTAssertEqual(again.loadValue, 30)
        again.loadValue = 40
        XCTAssertTrue(model.advice(for: again).contains { $0.kind == .intensityJump })
        model.update(again)
        model.finishWorkout()

        let quads = try XCTUnwrap(model.tissueWeeks().first { $0.tissue.id == "quads" && $0.side == .right })
        XCTAssertGreaterThan(quads.week, 24)
        XCTAssertNil(model.tissueWeeks().first { $0.tissue.id == "quads" && $0.side == .left })

        // The export is the whole record and merges into an empty device.
        let other = try makeModel()
        XCTAssertGreaterThan(other.merge(try XCTUnwrap(model.exportJSON())), 0)
        XCTAssertEqual(other.workouts.count, 2)
        XCTAssertEqual(other.injuries.first?.label, "Right quad strain")
    }

    func testAnEmptyWorkoutIsDiscarded() throws {
        let model = try makeModel()
        model.startWorkout()
        model.finishWorkout()
        XCTAssertNil(model.active)
        XCTAssertTrue(model.workouts.isEmpty)
    }
}
