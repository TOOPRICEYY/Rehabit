import XCTest
@testable import RehabitCore

// Adversarial tests of the load model and the logic behind the screens.
// A test that fails here is meant to show a defect in the source, and its
// comment says what the person using the app would see.

private let detroit = TimeZone(identifier: "America/Detroit")!
private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

private func iso(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

private func lset(_ day: Day, _ exercise: String = "Bench Press (Dumbbell)", pattern: String? = "press_horizontal",
                  side: Side = .both, kind: SetKind = .reps, reps: Double? = 10, hold: Double? = nil,
                  load: Double?) -> LedgerSet {
    LedgerSet(day: day, exercise: exercise, pattern: pattern, side: side, kind: kind, reps: reps,
              holdSeconds: hold, loadKg: load)
}

private func localHour(_ date: Date, _ zone: TimeZone) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar.component(.hour, from: date)
}

// MARK: - Ledger

final class LedgerStressTests: XCTestCase {
    let d0 = Day("2025-03-03")!
    let ledger = Ledger()

    func testDoseIsShareTimesRepsTimesSquaredRatioAndSameDaySetsDoNotMoveTheReference() {
        let sets = [
            lset(d0, load: 20),
            lset(d0.adding(1), load: 20),
            lset(d0.adding(1), load: 30),          // heavier, same day: must not lower the next set's ratio
            lset(d0.adding(1), load: 20),
        ]
        let doses = ledger.setDoses(sets)
        XCTAssertEqual(doses.map(\.ratio), [1, 1, 1.5, 1])
        XCTAssertEqual(doses[2].dose, 10 * 2.25, accuracy: 1e-9)
        let days = ledger.tissueDays(sets)
        let pecLeft = days.first { $0.day == d0.adding(1) && $0.tissue == "pec_major" && $0.side == .left }!
        let delt = days.first { $0.day == d0.adding(1) && $0.tissue == "front_delt" && $0.side == .right }!
        XCTAssertEqual(pecLeft.dose, 10 + 22.5 + 10, accuracy: 1e-9)       // share 1, "both" loads left...
        XCTAssertEqual(delt.dose, 0.5 * 42.5, accuracy: 1e-9)              // ...and right, assist share 0.5
        XCTAssertEqual(pecLeft.sets, 3)
    }

    func testTheReferenceWindowIsTheTwentyEightDaysBefore() {
        let sets = [lset(d0, load: 40), lset(d0.adding(28), load: 20), lset(d0.adding(29), load: 20)]
        let doses = ledger.setDoses(sets)
        XCTAssertEqual(doses[1].referenceKg, 40)          // day -28 is inside
        XCTAssertEqual(doses[2].referenceKg, 20)          // day -29 is not
    }

    func testSidesKeepTheirOwnReference() {
        let row = "Single-Arm Row (Dumbbell)"
        let sets = [
            lset(d0, row, pattern: "row", side: .left, load: 10),
            lset(d0, row, pattern: "row", side: .right, load: 30),
            lset(d0, row, pattern: "row", side: .both, load: 60),
            lset(d0.adding(2), row, pattern: "row", side: .left, load: 10),
            lset(d0.adding(2), row, pattern: "row", side: .right, load: 30),
        ]
        let doses = ledger.setDoses(sets)
        XCTAssertEqual(doses[3].referenceKg, 10)
        XCTAssertEqual(doses[3].ratio, 1)
        XCTAssertEqual(doses[4].referenceKg, 30)
        let days = ledger.tissueDays(sets)
        let midLeft = days.first { $0.day == d0 && $0.tissue == "mid_back" && $0.side == .left }!
        let midRight = days.first { $0.day == d0 && $0.tissue == "mid_back" && $0.side == .right }!
        XCTAssertEqual(midLeft.dose, 20, accuracy: 1e-9)       // left set + both set
        XCTAssertEqual(midRight.dose, 20, accuracy: 1e-9)      // right set + both set
    }

    func testNamesDifferingInCaseOrOuterSpacesShareAReference() {
        let sets = [lset(d0, "Bench Press (Dumbbell)", load: 20), lset(d0.adding(1), "  bench PRESS (dumbbell) ", load: 30)]
        XCTAssertEqual(ledger.setDoses(sets)[1].referenceKg, 20)
        XCTAssertEqual(ledger.setDoses(sets)[1].ratio, 1.5)
    }

    func testHoldsCountSecondsOverFiveAndAHoldWithNoSecondsCountsNothing() {
        let sets = [
            lset(d0, "Plank", pattern: "core", kind: .hold, reps: 12, hold: 33, load: nil),
            lset(d0, "Plank", pattern: "core", kind: .hold, reps: 12, hold: nil, load: nil),
        ]
        let doses = ledger.setDoses(sets)
        XCTAssertEqual(doses[0].effectiveReps, 6.6, accuracy: 1e-9)        // reps on a hold are ignored
        XCTAssertEqual(doses[1].effectiveReps, 0)
        XCTAssertEqual(doses[1].dose, 0)
    }

    func testASetWithNoPatternAddsNoTissueLoad() {
        let sets = [lset(d0, "Mystery Movement", pattern: nil, load: 30), lset(d0, "Odd Thing", pattern: "not_a_pattern", load: 30)]
        XCTAssertTrue(ledger.tissueDays(sets).allSatisfy { $0.dose == 0 })
        XCTAssertTrue(ledger.tissueDays([sets[0]]).isEmpty)
    }

    /// The ledger is a port of `service/rehabit/ledger.py`. These ratios were
    /// produced by running the Python `set_doses` over the same inputs
    /// (case and spacing in names, negative, zero and huge loads, negative reps,
    /// a hold with no seconds, the window edge). A negative load is treated as
    /// no load and negative reps as none, on both sides.
    func testParityWithPythonOnEdgeInputs() {
        let plan: [(Int, String, String, Side, SetKind, Double?, Double?, Double?)] = [
            (0, "Bench Press (Dumbbell)", "press_horizontal", .both, .reps, 10, nil, 20),
            (1, "bench press (dumbbell) ", "press_horizontal", .both, .reps, 10, nil, 30),
            (2, "Bench Press (Dumbbell)\n", "press_horizontal", .both, .reps, 10, nil, 20),
            (3, "Bench Press (Dumbbell)\t", "press_horizontal", .both, .reps, 10, nil, 20),
            (4, "Bench  Press (Dumbbell)", "press_horizontal", .both, .reps, 10, nil, 20),
            (5, "Single-Arm Row (Dumbbell)", "row", .left, .reps, 8, nil, -10),
            (6, "Single-Arm Row (Dumbbell)", "row", .left, .reps, 8, nil, 20),
            (7, "Single-Arm Row (Dumbbell)", "row", .left, .reps, 8, nil, 0),
            (8, "Single-Arm Row (Dumbbell)", "row", .left, .reps, -5, nil, 20),
            (9, "Plank", "core", .both, .hold, nil, nil, nil),
            (9, "Plank", "core", .both, .hold, 12, 33, nil),
            (10, "Single-Arm Row (Dumbbell)", "row", .right, .reps, 8, nil, 1e9),
            (11, "Single-Arm Row (Dumbbell)", "row", .right, .reps, 8, nil, 20),
            (28, "Bench Press (Dumbbell)", "press_horizontal", .both, .reps, 10, nil, 20),
            (29, "Bench Press (Dumbbell)", "press_horizontal", .both, .reps, 10, nil, 10),
            (30, "Bench Press (Dumbbell)", "press_horizontal", .both, .reps, 10, nil, 10),
        ]
        let python: [(ratio: Double, dose: Double)] = [
            (1.0, 10.0), (1.5, 22.5), (2.0 / 3, 4.444444444444445), (2.0 / 3, 4.444444444444445), (1.0, 10.0),
            (1.0, 8.0), (1.0, 8.0), (1.0, 8.0), (1.0, 0.0), (1.0, 0.0), (1.0, 6.6), (1.0, 8.0), (0.25, 0.5),
            (2.0 / 3, 4.444444444444445), (1.0 / 3, 1.1111111111111112), (0.5, 2.5),
        ]
        let sets = plan.map { lset(d0.adding($0.0), $0.1, pattern: $0.2, side: $0.3, kind: $0.4, reps: $0.5, hold: $0.6, load: $0.7) }
        let doses = ledger.setDoses(sets)
        XCTAssertEqual(doses.count, python.count)
        for (i, (mine, theirs)) in zip(doses, python).enumerated() {
            XCTAssertEqual(mine.ratio, theirs.ratio, accuracy: 1e-9, "set \(i) \(plan[i].1.debugDescription) ratio")
            XCTAssertEqual(mine.dose, theirs.dose, accuracy: 1e-9, "set \(i) \(plan[i].1.debugDescription) dose")
        }
    }

    /// A typo of "-10" (or a minus from a stray keypress) becomes the reference:
    /// the next real set at 20 kg is then read as a quarter of "usual" and its
    /// dose drops to 1/16. A negative load should count as no load.
    func testANegativeLoadDoesNotBecomeTheReference() {
        let row = "Single-Arm Row (Dumbbell)"
        let sets = [lset(d0, row, pattern: "row", side: .left, load: -10),
                    lset(d0.adding(1), row, pattern: "row", side: .left, load: 20)]
        let doses = ledger.setDoses(sets)
        XCTAssertNil(doses[1].referenceKg, "a negative load was used as the reference")
        XCTAssertEqual(doses[1].ratio, 1)
    }

    /// Negative reps (or hold seconds) subtract load from the tissue, so a typo
    /// can hide real work in the weekly totals.
    func testNegativeRepsDoNotSubtractLoad() {
        let sets = [lset(d0, load: 20), lset(d0, reps: -30, load: 20)]
        let pec = ledger.tissueDays(sets).first { $0.tissue == "pec_major" && $0.side == .left }!
        XCTAssertGreaterThanOrEqual(pec.dose, 10, "negative reps reduced the day's dose to \(pec.dose)")
        let hold = ledger.setDoses([lset(d0, "Plank", pattern: "core", kind: .hold, reps: nil, hold: -60, load: nil)])
        XCTAssertGreaterThanOrEqual(hold[0].dose, 0)
    }

    /// Defensible but surprising (same in Python): one typo of 2000 instead of
    /// 20 keeps every normal set at the minimum ratio for 28 days.
    func testDesignAHugeTypoSuppressesTheNextFourWeeks() {
        let sets = [lset(d0, load: 2000), lset(d0.adding(1), load: 20), lset(d0.adding(27), load: 20)]
        let doses = ledger.setDoses(sets)
        XCTAssertEqual(doses[1].ratio, 0.25)
        XCTAssertEqual(doses[2].ratio, 0.25)
        XCTAssertEqual(doses[2].dose, 10 * 0.0625, accuracy: 1e-9)
    }

    // MARK: Load conventions

    func pullUp(_ convention: LoadConvention, _ value: Double?, _ unit: WeightUnit = .kg, name: String = "Weighted Pull-Up") -> WorkoutSet {
        WorkoutSet(workout: Workout(), position: 0, exercise: name, pattern: "pull_up", reps: 5, loadValue: value,
                   loadUnit: unit, convention: convention)
    }

    func testConventions() {
        let known = Profile(bodyweightKg: 80, unit: .kg)
        XCTAssertEqual(ledger.loadKg(pullUp(.bodyweightPlus, 10), profile: known)!, 90, accuracy: 1e-9)
        XCTAssertEqual(ledger.loadKg(pullUp(.bodyweightPlus, nil), profile: known)!, 80, accuracy: 1e-9)
        XCTAssertEqual(ledger.loadKg(pullUp(.bodyweight, 999), profile: known)!, 80, accuracy: 1e-9)   // typed number ignored
        XCTAssertNil(ledger.loadKg(pullUp(.bodyweight, nil), profile: Profile()))
        XCTAssertEqual(ledger.loadKg(pullUp(.perHand, 50, .lb), profile: known)!, 22.6796185, accuracy: 1e-6)
        XCTAssertNil(ledger.loadKg(pullUp(.total, nil), profile: known))
        // Push-up: 64 percent of body weight.
        let push = WorkoutSet(workout: Workout(), position: 0, exercise: "Push-Up", pattern: "push_up", convention: .bodyweight)
        XCTAssertEqual(ledger.loadKg(push, profile: known)!, 51.2, accuracy: 1e-9)
    }

    /// With body weight unknown, "body weight plus 10 kg" is recorded as 10 kg,
    /// i.e. body weight is taken as zero. Then +15 kg reads as a 50 percent jump
    /// when the real change is about 6 percent. Unknown must stay unknown.
    func testBodyweightPlusWithUnknownBodyweightStaysUnknown() {
        XCTAssertNil(ledger.loadKg(pullUp(.bodyweightPlus, 10), profile: Profile()),
                     "body weight plus 10 kg with no body weight was taken as 10 kg")
    }

    func testAUnitSwitchMidHistoryComparesLikeWithLike() {
        let profile = Profile()
        var a = pullUp(.total, 100, .lb, name: "Bench Press (Barbell)"); a.pattern = "press_horizontal"
        var b = pullUp(.total, 45.359237, .kg, name: "Bench Press (Barbell)"); b.pattern = "press_horizontal"
        let first = ledger.ledgerSet(a, profile: profile)
        var second = ledger.ledgerSet(b, profile: profile)
        second.day = first.day.adding(2)
        let doses = ledger.setDoses([first, second])
        XCTAssertEqual(doses[1].ratio, 1, accuracy: 1e-9)
        XCTAssertTrue(Advisor().advice(for: second, history: [first]).isEmpty)
    }
}

// MARK: - Advisor

final class AdvisorStressTests: XCTestCase {
    let d0 = Day("2025-03-03")!
    let advisor = Advisor()

    func testSameDaySetsAreNotHistory() {
        // A heavy top set earlier today is not the "heaviest in 28 days" for a back-off set.
        let history = [lset(d0, load: 20), lset(d0.adding(3), load: 30)]
        XCTAssertEqual(advisor.advice(for: lset(d0.adding(3), load: 21), history: history).map(\.kind), [])
        XCTAssertEqual(advisor.advice(for: lset(d0.adding(3), load: 23), history: history).map(\.kind), [.intensityJump])
    }

    func testJumpIsAgainstTheSameSideOnly() {
        let row = "Single-Arm Row (Dumbbell)"
        let history = [lset(d0, row, pattern: "row", side: .right, load: 30), lset(d0, row, pattern: "row", side: .left, load: 10)]
        let left = lset(d0.adding(2), row, pattern: "row", side: .left, load: 12)
        XCTAssertTrue(advisor.advice(for: left, history: history).contains { $0.kind == .intensityJump })
        let right = lset(d0.adding(2), row, pattern: "row", side: .right, load: 30)
        XCTAssertFalse(advisor.advice(for: right, history: history).contains { $0.kind == .intensityJump })
    }

    func testLayoffReEntryAndThresholdEdges() {
        let history = [lset(d0, load: 20)]
        XCTAssertFalse(advisor.advice(for: lset(d0.adding(6), load: 20), history: history).contains { $0.kind == .layoff })
        XCTAssertTrue(advisor.advice(for: lset(d0.adding(7), load: 20), history: history).contains { $0.kind == .layoff })
        XCTAssertFalse(advisor.advice(for: lset(d0.adding(7), load: 19), history: history).contains { $0.kind == .layoff })
        XCTAssertFalse(advisor.advice(for: lset(d0.adding(20), load: 20), history: history).contains { $0.kind == .reEntry })
        let back = advisor.advice(for: lset(d0.adding(21), load: 20), history: history)
        XCTAssertTrue(back.contains { $0.kind == .reEntry && $0.detail.contains("21 days") })
        // Exactly ten percent is not "more than ten percent".
        XCTAssertFalse(advisor.advice(for: lset(d0.adding(1), load: 22), history: history).contains { $0.kind == .intensityJump })
    }

    func testInjuryNotesFollowSideAndResolution() {
        var pec = Injury(label: "Right pec", side: .right, onset: d0, tissues: ["pec_major"])
        let both = lset(d0.adding(1), load: 20)
        let notes = advisor.advice(for: both, history: [], injuries: [pec]).filter { $0.kind == .injuredTissue }
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].detail.contains("(right)"))
        let left = lset(d0.adding(1), "Single-Arm Bench Press (Dumbbell)", side: .left, load: 20)
        XCTAssertTrue(advisor.advice(for: left, history: [], injuries: [pec]).isEmpty)
        pec.resolvedOn = d0.adding(1)
        XCTAssertTrue(advisor.advice(for: both, history: [], injuries: [pec]).isEmpty)
        // A tissue carried at less than a quarter does not count: rows load pec_major at 0.1.
        let rowPec = Injury(label: "Pec", side: .both, onset: d0, tissues: ["pec_major"])
        let row = lset(d0.adding(1), "Seated Row (Cable)", pattern: "row", load: 40)
        XCTAssertTrue(advisor.advice(for: row, history: [], injuries: [rowPec]).isEmpty)
    }

    func testANoPatternSetGetsLoadNotesButNoTissueNotes() {
        let history = [lset(d0, "Mystery", pattern: nil, load: 20)]
        let kinds = advisor.advice(for: lset(d0.adding(30), "Mystery", pattern: nil, load: 30), history: history,
                                   injuries: [Injury(label: "x", side: .both, onset: d0, tissues: ["pec_major"])]).map(\.kind)
        XCTAssertEqual(kinds, [.layoff])     // 20 kg is outside the 28-day window, so no jump either
    }
}

// MARK: - Pain schedule

final class PainScheduleStressTests: XCTestCase {
    let injury = Injury(label: "Right quad", side: .right, onset: Day("2025-10-01")!, tissues: ["quads"])

    func checks(end: Date, start: Date? = nil, zone: TimeZone = detroit) -> [PainCheck] {
        PainSchedule(zone: zone).checks(for: injury, workout: Workout(start: start ?? end.addingTimeInterval(-3600), zone: zone),
                                        endedAt: end)
    }

    func testFallBackDay() {
        let c = checks(end: iso("2025-11-01T19:00:00Z"))               // Sat 15:00 EDT; clocks go back that night
        XCTAssertEqual(c.map(\.moment), [.afterSession, .evening, .nextMorning, .hours24, .hours48])
        XCTAssertEqual(c[1].dueAt, iso("2025-11-02T01:00:00Z"))         // 21:00 EDT
        XCTAssertEqual(c[2].dueAt, iso("2025-11-02T13:00:00Z"))         // 08:00 EST
        XCTAssertEqual(c[3].dueAt, iso("2025-11-02T19:00:00Z"))         // 24 elapsed hours (14:00 EST)
        XCTAssertEqual(c[2].dueDay.description, "2025-11-02")
    }

    func testSpringForwardDay() {
        let c = checks(end: iso("2026-03-07T20:00:00Z"))               // Sat 15:00 EST
        XCTAssertEqual(c.first { $0.moment == .nextMorning }?.dueAt, iso("2026-03-08T12:00:00Z"))   // 08:00 EDT
    }

    func testEveningCutOffIsTwentyTwoHundred() {
        XCTAssertTrue(checks(end: iso("2025-11-17T20:59:59Z")).contains { $0.moment == .evening })     // 15:59:59 -> 21:59:59
        XCTAssertFalse(checks(end: iso("2025-11-17T21:00:00Z")).contains { $0.moment == .evening })    // 16:00 -> 22:00
    }

    /// A session from 23:15 to 00:40 (common for night-shift or late gym-goers).
    /// The "next morning" check lands at 08:00 the day after tomorrow, 31 hours
    /// later and after the 24 h check, so the morning after the session is
    /// never asked about as a morning; instead an "evening" check is due at
    /// 06:40 in the morning.
    func testAWorkoutThatEndsAfterMidnightAsksTheComingMorning() {
        let start = iso("2025-11-17T04:15:00Z"), end = iso("2025-11-17T05:40:00Z")   // 23:15 -> 00:40 local
        let c = checks(end: end, start: start)
        let morning = try! XCTUnwrap(c.first { $0.moment == .nextMorning })
        XCTAssertEqual(morning.dueAt, iso("2025-11-17T13:00:00Z"),
                       "next-morning check is \(morning.dueAt.timeIntervalSince(end) / 3600) h after the session")
        if let evening = c.first(where: { $0.moment == .evening }) {
            XCTAssertGreaterThanOrEqual(localHour(evening.dueAt, detroit), 12,
                                        "an 'evening' check is due at \(localHour(evening.dueAt, detroit)):40 in the morning")
        }
    }

    func testAnotherZoneUsesItsOwnClock() {
        let c = checks(end: iso("2025-11-17T05:00:00Z"), zone: tokyo)    // 14:00 JST
        XCTAssertEqual(c.first { $0.moment == .evening }?.dueAt, iso("2025-11-17T11:00:00Z"))
        XCTAssertEqual(c.first { $0.moment == .nextMorning }?.dueAt, iso("2025-11-17T23:00:00Z"))
    }

    func testSettlingKeepsMissingAsMissing() {
        let end = iso("2025-11-17T20:00:00Z")
        func check(_ hours: Double, _ pain: Double?) -> PainCheck {
            var c = PainCheck(injuryID: "i", workoutID: "w", moment: .evening, dueAt: end.addingTimeInterval(hours * 3600))
            c.pain = pain
            c.answeredAt = pain == nil ? nil : c.dueAt
            return c
        }
        let none = SettlingSummary(checks: [check(0, nil), check(6, nil)], baseline: 2, sessionEnd: end)
        XCTAssertNil(none.peak)
        XCTAssertNil(none.hoursToSettle)
        XCTAssertEqual(none.answered, 0)
        XCTAssertEqual(none.asked, 2)
        // Within half a point counts as settled; a later flare un-settles the earlier reading.
        let s = SettlingSummary(checks: [check(0, 2.5), check(6, 4), check(24, 2.5), check(48, 2)], baseline: 2, sessionEnd: end)
        XCTAssertEqual(s.peak, 4)
        XCTAssertEqual(s.hoursToSettle, 24)
        // Order of input does not matter.
        let shuffled = SettlingSummary(checks: [check(48, 2), check(6, 4), check(24, 2.5), check(0, 2.5)], baseline: 2, sessionEnd: end)
        XCTAssertEqual(shuffled, s)
    }
}

// MARK: - App model

final class AppModelStressTests: XCTestCase {
    var clock = iso("2025-11-17T17:00:00Z")                 // Monday 12:00 in Detroit
    var paths: [String] = []

    override func tearDown() {
        for p in paths { try? FileManager.default.removeItem(atPath: p) }
        super.tearDown()
    }

    func tempPath() -> String {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("rehabit-\(UUID().uuidString).sqlite").path
        paths.append(p)
        return p
    }

    func makeModel(_ store: Store? = nil, zone: TimeZone = detroit) throws -> AppModel {
        AppModel(store: try store ?? Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
    }

    func entry(_ name: String, _ model: AppModel) -> CatalogueExercise { model.library.catalogue.first { $0.name == name }! }

    func quad(_ side: Side = .right, onset: String = "2025-11-01") -> Injury {
        Injury(label: "\(side.rawValue) quad", side: side, onset: Day(onset)!, tissues: ["quads"])
    }

    /// Logs one finished workout with one set and moves the clock on.
    @discardableResult
    func logWorkout(_ model: AppModel, _ name: String, side: Side? = nil, reps: Double = 10, load: Double? = 20,
                    pain: Double? = nil) -> WorkoutSet {
        model.startWorkout()
        var s = model.addSet(entry(name, model), side: side)!
        s.reps = reps; s.loadValue = load; s.pain = pain
        model.update(s)
        clock.addTimeInterval(3600)
        model.finishWorkout()
        return s
    }

    func testAddSetWithNoWorkoutDoesNothing() throws {
        let model = try makeModel()
        XCTAssertNil(model.addSet(entry("Push-Up", model)))
        XCTAssertTrue(try XCTUnwrap(model.exportJSON()).count > 0)
        model.finishWorkout(); model.discardWorkout(); model.renameActive("x")
        XCTAssertNil(model.active)
        XCTAssertTrue(model.workouts.isEmpty)
    }

    func testRepeatCopiesTheSetButNeverItsPainAndPrefillIsPerSide() throws {
        let model = try makeModel()
        let row = entry("Single-Arm Row (Dumbbell)", model)
        model.startWorkout()
        var l = model.addSet(row, side: .left)!
        l.reps = 12; l.loadValue = 25; l.pain = 3; l.painType = .sharp; l.notes = "twinge"; l.repsInReserve = 2
        model.update(l)
        var r = model.addSet(row, side: .right)!
        XCTAssertNil(r.loadValue)                       // the other side is not copied
        r.reps = 8; r.loadValue = 40
        model.update(r)
        let l2 = model.addSet(row, side: .left)!
        XCTAssertEqual(l2.loadValue, 25)
        XCTAssertEqual(l2.reps, 12)
        XCTAssertNil(l2.pain); XCTAssertNil(l2.painType); XCTAssertEqual(l2.notes, ""); XCTAssertNil(l2.repsInReserve)
        XCTAssertEqual(model.activeSets.map(\.position), [0, 1, 2])
        clock.addTimeInterval(3600)
        model.finishWorkout()

        clock.addTimeInterval(2 * 86_400)
        model.startWorkout()
        let nextLeft = model.addSet(row, side: .left)!
        XCTAssertEqual(nextLeft.loadValue, 25)          // from the last finished session, same side
        XCTAssertNil(nextLeft.pain)
        let nextRight = model.addSet(row, side: .right)!
        XCTAssertEqual(nextRight.loadValue, 40)
    }

    func testOneSidedDefaultSkipsAResolvedInjury() throws {
        let model = try makeModel()
        var healed = quad(.left, onset: "2025-11-10")
        healed.resolvedOn = Day("2025-11-15")
        model.save(healed)
        model.save(quad(.right))
        model.startWorkout()
        XCTAssertEqual(model.addSet(entry("Single-Leg Extension (Machine)", model))?.side, .right)
        XCTAssertEqual(model.addSet(entry("Leg Extension (Machine)", model))?.side, .both)
    }

    /// Two active injuries: a right quad strain (older) and a left pec strain
    /// (newer). Adding a single-leg extension, which only loads the quad,
    /// defaults to the LEFT leg because the newest active injury is on the left.
    /// The person ends up logging rehab on the healthy leg unless they notice.
    func testOneSidedDefaultUsesTheInjuryThatTheExerciseLoads() throws {
        let model = try makeModel()
        model.save(quad(.right, onset: "2025-10-01"))
        model.save(Injury(label: "Left pec", side: .left, onset: Day("2025-11-10")!, tissues: ["pec_major"]))
        model.startWorkout()
        let set = try XCTUnwrap(model.addSet(entry("Single-Leg Extension (Machine)", model)))
        XCTAssertEqual(set.side, .right, "defaulted to the side of an injury this exercise does not load")
    }

    func testRelaunchWithAWorkoutInProgress() throws {
        let path = tempPath()
        var s: WorkoutSet
        do {
            let model = try makeModel(try Store(path: path))
            model.profile = Profile(bodyweightKg: 70, unit: .kg)
            model.save(quad())
            model.startWorkout(title: "Rehab")
            s = model.addSet(entry("Single-Leg Extension (Machine)", model))!
            s.reps = 10; s.loadValue = 30; s.pain = 2
            model.update(s)
        }
        clock.addTimeInterval(1800)
        let again = try makeModel(try Store(path: path))
        XCTAssertEqual(again.active?.title, "Rehab")
        XCTAssertEqual(again.activeSets.map(\.id), [s.id])
        XCTAssertEqual(again.activeSets.first?.pain, 2)
        XCTAssertEqual(again.profile.bodyweightKg, 70)
        XCTAssertEqual(again.profile.unit, .kg)
        let repeatSet = try XCTUnwrap(again.addSet(entry("Single-Leg Extension (Machine)", again)))
        XCTAssertEqual(repeatSet.loadValue, 30)
        XCTAssertEqual(repeatSet.unitTestKg, 30)
        XCTAssertEqual(again.finishWorkout().count, 1)
        XCTAssertEqual(again.upcomingChecks.filter { $0.workoutID != nil }.count, 4)
    }

    func testAWorkoutAcrossMidnightBelongsToTheDayItStarted() throws {
        clock = iso("2025-11-18T04:30:00Z")                       // Mon 23:30 local
        let model = try makeModel()
        model.save(quad())
        model.startWorkout()
        var s = model.addSet(entry("Single-Leg Extension (Machine)", model))!
        clock.addTimeInterval(3600)                                // Tue 00:30
        s.reps = 10; s.loadValue = 30
        model.update(s)
        let late = model.addSet(entry("Single-Leg Extension (Machine)", model))!
        XCTAssertEqual(late.workoutDay.description, "2025-11-17")
        XCTAssertEqual(model.finishWorkout().count, 1)
        XCTAssertEqual(model.workouts.first?.startDay.description, "2025-11-17")
        // Today is Tuesday; the Monday-night work is in this week's load.
        let quads = try XCTUnwrap(model.tissueWeeks().first { $0.tissue.id == "quads" && $0.side == .right })
        XCTAssertEqual(quads.week, 20, accuracy: 1e-9)
    }

    func testTissueWeeksIncludesTheWorkoutInProgressAndCountsSevenDaysAgainstTheTwentyEightBefore() throws {
        let model = try makeModel()
        let extensionName = "Leg Extension (Machine)"
        // 8 weeks ago: outside all windows. 10 and 20 days ago: the "usual" four weeks. 6 days ago: this week.
        for daysAgo in [56, 20, 10, 6] {
            clock = iso("2025-11-17T17:00:00Z").addingTimeInterval(-Double(daysAgo) * 86_400)
            logWorkout(model, extensionName, reps: 10, load: 50)
        }
        clock = iso("2025-11-17T17:00:00Z")
        model.startWorkout()
        var s = model.addSet(entry(extensionName, model))!
        s.reps = 10; s.loadValue = 50
        model.update(s)
        let quads = try XCTUnwrap(model.tissueWeeks().first { $0.tissue.id == "quads" && $0.side == .left })
        XCTAssertEqual(quads.week, 20, accuracy: 1e-9)          // 6 days ago and today, in progress
        XCTAssertEqual(quads.usualWeek, 5, accuracy: 1e-9)      // 20 over four weeks
        XCTAssertEqual(quads.ratio!, 4, accuracy: 1e-9)
        model.discardWorkout()
        XCTAssertEqual(model.tissueWeeks().first { $0.tissue.id == "quads" && $0.side == .left }!.week, 10, accuracy: 1e-9)
    }

    /// The person trains in Tokyo on Monday morning and flies home to Detroit,
    /// where it is still Sunday evening. The app (relaunched in the new zone)
    /// drops Monday's session from "this week" because it is dated after "today".
    func testTissueWeeksAfterFlyingWestKeepsTodaysSession() throws {
        let path = tempPath()
        clock = iso("2025-11-17T01:00:00Z")                         // Mon 10:00 Tokyo, Sun 20:00 Detroit
        let inTokyo = try makeModel(try Store(path: path), zone: tokyo)
        logWorkout(inTokyo, "Leg Extension (Machine)", reps: 10, load: 50)
        XCTAssertEqual(inTokyo.tissueWeeks().first { $0.tissue.id == "quads" }?.week ?? 0, 10, accuracy: 1e-9)
        clock.addTimeInterval(3600)
        let home = try makeModel(try Store(path: path), zone: detroit)
        let week = home.tissueWeeks().first { $0.tissue.id == "quads" }?.week ?? 0
        XCTAssertEqual(week, 10, accuracy: 1e-9, "the session done an hour ago is missing from this week's load")
    }

    /// The model accepts and stores pain outside 0 to 10.
    func testAnsweringClampsPainToZeroToTen() throws {
        let model = try makeModel()
        let injury = quad()
        model.save(injury)
        logWorkout(model, "Single-Leg Extension (Machine)")
        let due = model.dueChecks
        XCTAssertEqual(due.count, 1)
        model.answer(due[0], pain: 14)
        model.logBaseline(injury: injury, pain: -3)
        let readings = model.painHistory(for: injury).compactMap(\.pain)
        XCTAssertEqual(readings.count, 2)
        XCTAssertTrue(readings.allSatisfy { (0...10).contains($0) }, "stored pain readings \(readings)")
    }

    func testAnsweringRoundsToHalfPointsAndMissingStaysMissing() throws {
        let model = try makeModel()
        let injury = quad()
        model.save(injury)
        logWorkout(model, "Single-Leg Extension (Machine)")
        model.answer(model.dueChecks[0], pain: 2.24, type: .ache)
        clock.addTimeInterval(5 * 86_400 + 1)
        // Everything else is now long overdue: off the list, still recorded, still nil.
        XCTAssertTrue(model.dueChecks.filter { $0.workoutID != nil }.isEmpty)
        let missing = model.checks.filter { !$0.isAnswered }
        XCTAssertEqual(missing.count, 4)
        XCTAssertTrue(missing.allSatisfy { $0.pain == nil })
        XCTAssertEqual(model.painHistory(for: injury).map(\.pain), [2])
        model.logBaseline(injury: injury, pain: 0.26)
        XCTAssertEqual(model.painHistory(for: injury).last?.pain, 0.5)
        XCTAssertEqual(model.painHistory(for: injury).last?.moment, .baseline)
    }

    /// A delayed question stays for half a day and no longer: at exactly that
    /// long it is still offered, a second later it is not.
    func testADelayedCheckLapsesAfterHalfADay() throws {
        let model = try makeModel()
        model.save(quad())
        logWorkout(model, "Single-Leg Extension (Machine)")
        let later = try XCTUnwrap(model.checks.first { $0.moment == .hours48 })
        clock = later.dueAt.addingTimeInterval(12 * 3600)
        XCTAssertTrue(model.dueChecks.contains { $0.id == later.id })
        clock = later.dueAt.addingTimeInterval(12 * 3600 + 1)
        XCTAssertFalse(model.dueChecks.contains { $0.id == later.id })
        // The after-session question is different: hours later it would be a
        // different reading, so it is only offered for three hours.
        let after = try XCTUnwrap(model.checks.first { $0.moment == .afterSession })
        clock = after.dueAt.addingTimeInterval(3 * 3600 + 1)
        XCTAssertFalse(model.dueChecks.contains { $0.id == after.id })
        XCTAssertNil(model.checks.first { $0.id == after.id }?.pain)
    }

    /// The person deletes the injury (logged by mistake, or a duplicate). Its
    /// pending checks stay on the due list, asking about an injury the app no
    /// longer has (the screen cannot even show its name).
    func testChecksOfADeletedInjuryLeaveTheDueList() throws {
        let model = try makeModel()
        let injury = quad()
        model.save(injury)
        logWorkout(model, "Single-Leg Extension (Machine)")
        model.deleteInjury(id: injury.id)
        XCTAssertTrue(model.injuries.isEmpty)
        let orphans = model.dueChecks.filter { c in !model.injuries.contains { $0.id == c.injuryID } }
        XCTAssertTrue(orphans.isEmpty, "\(orphans.count) due check(s) for a deleted injury")
        XCTAssertTrue(model.upcomingChecks.isEmpty, "\(model.upcomingChecks.count) reminders still scheduled for a deleted injury")
    }

    /// The person deletes a workout they logged by mistake. The pain checks it
    /// scheduled still come due and ask about a session that is gone.
    func testChecksOfADeletedWorkoutLeaveTheDueList() throws {
        let model = try makeModel()
        model.save(quad())
        logWorkout(model, "Single-Leg Extension (Machine)")
        model.deleteWorkout(try XCTUnwrap(model.workouts.first))
        XCTAssertTrue(model.workouts.isEmpty)
        let due = model.dueChecks.filter { $0.workoutID != nil }, coming = model.upcomingChecks.filter { $0.workoutID != nil }
        XCTAssertTrue(due.isEmpty, "\(due.count) due check(s) for a deleted workout")
        XCTAssertTrue(coming.isEmpty, "\(coming.count) reminders for a deleted workout")
    }

    /// A screen holding a copy of a set (an edit field still focused) writes it
    /// back after the set was removed; the removed set comes back.
    func testARemovedSetIsNotBroughtBackByALateEdit() throws {
        let model = try makeModel()
        model.startWorkout()
        var s = model.addSet(entry("Push-Up", model))!
        model.removeSet(id: s.id)
        XCTAssertTrue(model.activeSets.isEmpty)
        s.reps = 12
        model.update(s)
        XCTAssertTrue(model.activeSets.isEmpty, "the removed set came back")
    }

    /// Same, after the whole workout was discarded: the set is stored with no
    /// workout and still counts as history for the notes on later sets.
    func testALateEditAfterDiscardDoesNotLeaveAnOrphanSet() throws {
        let model = try makeModel()
        model.startWorkout()
        var s = model.addSet(entry("Bench Press (Dumbbell)", model))!
        s.reps = 10; s.loadValue = 100
        model.discardWorkout()
        model.update(s)                                  // late write from the discarded screen
        clock.addTimeInterval(86_400)
        model.startWorkout()
        var next = model.addSet(entry("Bench Press (Dumbbell)", model))!
        XCTAssertNil(next.loadValue)
        next.reps = 10; next.loadValue = 50
        let advice = model.advice(for: next)
        XCTAssertFalse(advice.contains { $0.kind == .density }, "a discarded set counts as yesterday's load: \(advice)")
    }

    func testEmptyFinishDiscardsAndAnEmptiedWorkoutToo() throws {
        let model = try makeModel()
        model.startWorkout()
        let s = model.addSet(entry("Push-Up", model))!
        model.removeSet(id: s.id)
        XCTAssertTrue(model.finishWorkout().isEmpty)
        XCTAssertNil(model.active)
        XCTAssertTrue(model.workouts.isEmpty)
        model.startWorkout()
        let first = model.active?.id
        model.startWorkout()                             // a second start does not open a second workout
        XCTAssertEqual(model.active?.id, first)
    }

    /// A set added and left blank (no reps, no seconds) was not done: it is not
    /// kept, loads nothing, and a session of nothing else is not kept either.
    func testABlankSetIsNotKeptAndSchedulesNothing() throws {
        let model = try makeModel()
        model.save(quad())
        model.startWorkout()
        _ = model.addSet(entry("Single-Leg Extension (Machine)", model))
        XCTAssertEqual(model.finishWorkout().count, 0)
        XCTAssertEqual(model.workouts.count, 0)
        XCTAssertTrue(model.checks.isEmpty)
    }

    /// The weighted pull-up end to end with body weight not yet entered.
    /// +10 kg then +15 kg is about 6 percent more weight moved, but is
    /// reported as "50 percent above the heaviest".
    func testWeightedPullUpWithoutBodyweightIsNotAFalseJump() throws {
        let model = try makeModel()
        logWorkout(model, "Weighted Pull-Up", reps: 5, load: 10)
        clock.addTimeInterval(2 * 86_400)
        model.startWorkout()
        var s = model.addSet(entry("Weighted Pull-Up", model))!
        s.loadValue = 15
        let jump = model.advice(for: s).filter { $0.kind == .intensityJump }
        XCTAssertTrue(jump.isEmpty, "with body weight unknown: \(jump.map(\.detail))")
    }

    func testBodyweightIsReadAtComputeTimeSoHistoryFollowsTheCurrentWeight() throws {
        // Design: the profile holds one body weight, so changing it re-weights all past
        // body-weight sets. Ratios within one exercise are unaffected, so doses do not move.
        let model = try makeModel()
        model.profile = Profile(bodyweightKg: 80, unit: .kg)
        logWorkout(model, "Push-Up", reps: 20, load: nil)
        let before = model.tissueWeeks().first { $0.tissue.id == "pec_major" }!.week
        model.profile = Profile(bodyweightKg: 60, unit: .kg)
        XCTAssertEqual(model.tissueWeeks().first { $0.tissue.id == "pec_major" }!.week, before, accuracy: 1e-9)
        model.profile = Profile()
        XCTAssertEqual(model.tissueWeeks().first { $0.tissue.id == "pec_major" }!.week, before, accuracy: 1e-9)
    }

    // MARK: Performance

    /// About three and a half years of training: 3 sessions a week, 9 sets each.
    func seededModel(sets target: Int) throws -> (AppModel, Double, Store) {
        let path = tempPath()
        let store = try Store(path: path)
        let names = ["Bench Press (Dumbbell)", "Single-Arm Row (Dumbbell)", "Squat (Barbell)", "Lat Pulldown (Cable)",
                     "Single-Leg Extension (Machine)", "Romanian Deadlift (Barbell)", "Shoulder Press (Dumbbell)",
                     "Biceps Curl (Dumbbell)", "Plank"]
        let library = Library.standard
        var workouts: [Workout] = [], sets: [WorkoutSet] = []
        let end = iso("2025-11-16T17:00:00Z")
        var session = 0
        while sets.count < target {
            let start = end.addingTimeInterval(-Double(session) * 2.33 * 86_400)
            var w = Workout(title: "W\(session)", start: start, zone: detroit)
            w.end = start.addingTimeInterval(3600)
            workouts.append(w)
            for i in 0..<9 where sets.count < target {
                let e = library.catalogue.first { $0.name == names[i] }!
                let side: Side = e.unilateral ? (i % 2 == 0 ? .left : .right) : .both
                var s = WorkoutSet(workout: w, position: i, exercise: e.name, pattern: e.pattern, side: side,
                                   reps: 8 + Double(session % 5), loadValue: 20 + Double(session % 7) * 2.5,
                                   loadUnit: .kg, convention: e.convention, pain: session % 3 == 0 ? 1 : nil,
                                   updatedAt: start)
                if e.name == "Plank" { s.kind = .hold; s.holdSeconds = 45; s.reps = nil; s.loadValue = nil }
                sets.append(s)
            }
            session += 1
        }
        try store.merge(Snapshot(exportedAt: end, profile: Profile(bodyweightKg: 80, unit: .kg), workouts: workouts,
                                 sets: sets, injuries: [quad(onset: "2024-01-01")], painChecks: [], dailyMetrics: [],
                                 tombstones: []))
        store.profile = Profile(bodyweightKg: 80, unit: .kg)
        clock = iso("2025-11-17T17:00:00Z")
        let model = try makeModel(store)
        return (model, Double(session), store)
    }

    func time(_ body: () -> Void) -> Double {
        let t = Date()
        body()
        return Date().timeIntervalSince(t) * 1000
    }

    /// The screens call `advice(for:)` on every keystroke, and every edit
    /// (`update`) reloads the whole store, so one keystroke costs an update plus
    /// an advice. With 4,500 sets (3.5 years) that should stay under 100 ms,
    /// a generous ceiling for typing to feel immediate.
    func testPerformanceWithThousandsOfSets() throws {
        let (model, sessions, store) = try seededModel(sets: 4500)
        let ledger = Ledger()
        let ledgerSets = try store.all(WorkoutSet.self).map { ledger.ledgerSet($0, profile: model.profile) }
        let mapMs = time { _ = try? store.all(WorkoutSet.self).map { ledger.ledgerSet($0, profile: model.profile) } }
        let dosesMs = time { _ = ledger.setDoses(ledgerSets) }
        var dayCount = 0
        let daysMs = time { dayCount = ledger.tissueDays(ledgerSets).count }
        print(String(format: "PERF parts: store read+map %.1f ms, setDoses %.1f ms, tissueDays %.1f ms (%d rows)",
                     mapMs, dosesMs, daysMs, dayCount))
        XCTAssertEqual(model.workouts.count, Int(sessions))
        model.startWorkout()
        var s = model.addSet(entry("Single-Leg Extension (Machine)", model))!
        s.loadValue = 40
        var adviceMs: [Double] = [], reloadMs: [Double] = [], updateMs: [Double] = [], weeksMs: [Double] = []
        for i in 0..<5 {
            s.reps = Double(10 + i)
            adviceMs.append(time { _ = model.advice(for: s) })
            reloadMs.append(time { model.reload() })
            updateMs.append(time { model.update(s) })
            weeksMs.append(time { _ = model.tissueWeeks() })
        }
        func median(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }
        print(String(format: "PERF 4500 sets: advice %.1f ms, reload %.1f ms, update %.1f ms, tissueWeeks %.1f ms (median of 5)",
                     median(adviceMs), median(reloadMs), median(updateMs), median(weeksMs)))
        XCTAssertLessThan(median(adviceMs) + median(updateMs), 100, "one keystroke: update() (with a full reload) plus advice(for:)")
    }
}

private extension WorkoutSet {
    /// The load this set stands for in kilograms, for a `.total` set.
    var unitTestKg: Double? { loadValue.map { $0 * loadUnit.kilograms } }
}
