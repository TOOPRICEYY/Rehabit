import XCTest
@testable import RehabitCore

final class CheckInTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 0)

    func at(_ text: String) -> Date {   // local time, "2026-11-16 10:00"
        GarminClient.localTime(text + ":00", zone: zone)!
    }

    func model() throws -> AppModel {
        AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
    }

    func entry(_ name: String, _ m: AppModel) -> CatalogueExercise { m.library.catalogue.first { $0.name == name }! }

    /// A finished session of one exercise, ending at the current clock time.
    @discardableResult
    func session(_ m: AppModel, _ name: String, side: Side, minutes: Double = 30) -> Workout {
        clock.addTimeInterval(-minutes * 60)
        m.startWorkout()
        var s = m.addSet(entry(name, m), side: side)!
        s.reps = 10; s.loadValue = 20
        m.update(s)
        clock.addTimeInterval(minutes * 60)
        m.finishWorkout()
        return m.workouts.first!
    }

    func testSixInjuriesAreOneScreenAndOneReminder() throws {
        clock = at("2026-11-16 21:00")
        let m = try model()
        let tissues = ["pec_major", "triceps", "biceps", "quads", "calf", "glute_max"]
        for (i, tissue) in tissues.enumerated() {
            m.save(Injury(label: "Injury \(i)", side: i % 2 == 0 ? .left : .right, onset: Day("2026-01-01")!, tissues: [tissue]))
        }
        // Late evening: the morning's question lapsed after twelve hours, nothing is due.
        XCTAssertTrue(m.dueChecks.isEmpty)
        // Tomorrow morning is one reminder for all six, and so is each morning after it.
        let rounds = m.reminderRounds
        XCTAssertEqual(rounds.count, 7)
        XCTAssertEqual(rounds[0].fireAt, at("2026-11-17 08:00"))
        XCTAssertEqual(rounds[0].injuryLabels.count, 6)
        XCTAssertEqual(rounds[0].title, "Pain check-in for 6 injuries")
        XCTAssertEqual(Set(rounds.map(\.id)).count, 7)
        XCTAssertTrue(m.checks.isEmpty)                                   // nothing is stored for a question not yet answered

        clock = at("2026-11-17 08:05")
        let round = m.checkInRound
        XCTAssertEqual(round.map(\.injury.label), (0..<6).map { "Injury \($0)" })
        XCTAssertTrue(round.allSatisfy { $0.check.moment == .baseline && $0.last == nil })

        // Nothing to copy yet, so "unchanged" answers none and hands all six back.
        XCTAssertEqual(m.answerUnchanged(round.map(\.check)).count, 6)
        m.answer(round.prefix(4).map { (check: $0.check, pain: 2.2, type: PainType?.none, notes: "") })
        m.skip(round.suffix(2).map(\.check))
        XCTAssertTrue(m.dueChecks.isEmpty)
        XCTAssertEqual(m.checks.filter(\.isAnswered).map(\.pain), [2, 2, 2, 2])
        XCTAssertEqual(m.checks.filter { $0.skippedAt != nil }.count, 2)
        XCTAssertTrue(m.checks.filter { $0.skippedAt != nil }.allSatisfy { $0.pain == nil })   // skipped is missing, not zero

        // The next morning the four with a reading can be answered in one tap.
        clock = at("2026-11-18 08:30")
        let next = m.checkInRound
        XCTAssertEqual(next.count, 6)
        XCTAssertEqual(next.filter { $0.last != nil }.count, 4)
        let left = m.answerUnchanged(next.map(\.check))
        XCTAssertEqual(left.count, 2)
        let carried = m.checks.filter { $0.source == PainCheck.unchanged }
        XCTAssertEqual(carried.map(\.pain), [2, 2, 2, 2])
        XCTAssertEqual(m.dueChecks.count, 2)
        XCTAssertNil(m.lastError)
    }

    func testTwoSessionsADayApartAskOnceAndTheMorningServesAsTheDaily() throws {
        clock = at("2026-11-16 10:00")
        let m = try model()
        m.save(Injury(label: "Quad", side: .right, onset: Day("2026-05-01")!, tissues: ["quads"]))
        let first = session(m, "Single-Leg Extension (Machine)", side: .right)
        // A morning session: next morning (8:00) and 24 hours (10:00) are one reading, the morning kept.
        XCTAssertEqual(m.checks.map(\.moment), [.afterSession, .evening, .nextMorning, .hours48])

        clock = at("2026-11-17 10:30")
        session(m, "Single-Leg Extension (Machine)", side: .right)
        // The first session's 48-hour question falls on Wednesday at 10:00. The second session's
        // next-morning (8:00) and 24-hour (10:30) questions are the same reading, so Wednesday
        // morning asks about the quad once.
        let wednesday = m.checks.filter { $0.dueDay == Day("2026-11-18") }
        XCTAssertEqual(wednesday.map(\.moment), [.hours48])
        XCTAssertEqual(wednesday.map(\.dueAt), [at("2026-11-18 10:00")])
        XCTAssertEqual(m.checks.filter { $0.dueDay == Day("2026-11-19") }.map(\.dueAt), [at("2026-11-19 10:30")])

        // Wednesday 10:05: one question about the quad.
        clock = at("2026-11-18 10:05")
        XCTAssertEqual(m.dueChecks.map(\.moment), [.hours48])
        // And no separate daily question that morning: the follow-up is the day's reading.
        XCTAssertFalse(m.upcomingChecks.contains { $0.dueDay == Day("2026-11-18") && $0.moment == .baseline })
        XCTAssertTrue(m.upcomingChecks.contains { $0.dueDay == Day("2026-11-20") && $0.moment == .baseline })
        XCTAssertEqual(first.id, m.workouts.last?.id)
    }

    func testSettlingNeedsADelayedReadingAndABaseline() throws {
        clock = at("2026-11-16 08:10")
        let m = try model()
        let injury = Injury(label: "Quad", side: .right, onset: Day("2026-05-01")!, tissues: ["quads"])
        m.save(injury)
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 1)               // the morning's reading: 1
        clock = at("2026-11-16 17:00")
        let workout = session(m, "Single-Leg Extension (Machine)", side: .right)
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 1)               // right after: still 1
        var settling = try XCTUnwrap(m.settling(for: workout).first)
        XCTAssertEqual(settling.baseline, 1)
        XCTAssertNil(settling.summary?.hoursToSettle)                     // one reading at the door proves nothing

        clock = at("2026-11-17 08:00")
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 3.5)             // next morning: worse
        clock = at("2026-11-18 17:00")
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 1.5)             // 48 hours: back within half a point
        settling = try XCTUnwrap(m.settling(for: workout).first)
        XCTAssertEqual(settling.readings.compactMap(\.pain), [1, 3.5, 1.5])
        XCTAssertEqual(settling.summary?.peak, 3.5)
        XCTAssertEqual(settling.summary?.hoursToSettle ?? 0, 48, accuracy: 0.01)

        // A flare-up logged in between counts as a reading; a session with no reading before it has no baseline.
        let other = Injury(label: "Calf", side: .left, onset: Day("2026-05-01")!, tissues: ["calf"])
        m.save(other)
        clock = at("2026-11-19 12:00")
        let second = session(m, "Single-Leg Calf Raise (Dumbbell)", side: .left)
        m.logPain([(injury: other, pain: 6.3, type: PainType?.none)], context: " stairs ")
        let calf = try XCTUnwrap(m.settling(for: second).first { $0.injury.id == other.id })
        XCTAssertNil(calf.baseline); XCTAssertNil(calf.summary)
        XCTAssertEqual(calf.readings.map(\.moment), [.flare])
        XCTAssertEqual(calf.readings.first?.pain, 6.5)
        XCTAssertEqual(calf.readings.first?.context, "stairs")
        XCTAssertNil(m.lastError)
    }

    func testEditingAWorkoutsEndAsksAgainFromTheNewTime() throws {
        clock = at("2026-11-16 20:00")
        let m = try model()
        m.save(Injury(label: "Quad", side: .right, onset: Day("2026-05-01")!, tissues: ["quads"]))
        var workout = session(m, "Single-Leg Extension (Machine)", side: .right)
        XCTAssertEqual(m.checks.map(\.moment), [.afterSession, .nextMorning, .hours24, .hours48])
        // It was really done at half past nine in the morning.
        workout.start = at("2026-11-16 09:00"); workout.end = at("2026-11-16 09:30")
        m.update(workout)
        // "Right after" lapsed hours ago and is not asked. The evening question (15:30) is still
        // within reach, and the rest follow the new end; 24 hours falls on the morning question.
        XCTAssertEqual(m.checks.map(\.moment), [.evening, .nextMorning, .hours48])
        XCTAssertEqual(m.checks.map(\.dueAt),
                       [at("2026-11-16 15:30"), at("2026-11-17 08:00"), at("2026-11-18 09:30")])
        XCTAssertEqual(m.dueChecks.map(\.moment), [.evening])
    }

    func testTheDailyQuestionCanBeTurnedOffAndOldRecordsStillRead() throws {
        clock = at("2026-11-17 09:00")
        let m = try model()
        m.save(Injury(label: "Quad", side: .right, onset: Day("2026-05-01")!, tissues: ["quads"]))
        XCTAssertEqual(m.dueChecks.count, 1)
        m.profile.dailyCheckIn = false
        XCTAssertTrue(m.dueChecks.isEmpty); XCTAssertTrue(m.reminderRounds.isEmpty)
        m.profile.dailyCheckIn = true
        m.profile.morningHour = 10
        XCTAssertTrue(m.dueChecks.isEmpty)                                // not yet 10
        XCTAssertEqual(m.reminderRounds.first?.fireAt, at("2026-11-17 10:00"))
        // A profile and a check written before these fields existed read with the defaults.
        let old = try JSONDecoder().decode(Profile.self, from: Data(#"{"bodyweightKg": 70, "unit": "kg"}"#.utf8))
        XCTAssertTrue(old.dailyCheckIn); XCTAssertEqual(old.morningHour, 8)
        // A resolved injury is not asked about.
        var injury = m.injuries[0]; injury.resolvedOn = Day("2026-11-16")
        m.save(injury)
        XCTAssertTrue(m.reminderRounds.isEmpty)
    }
}
