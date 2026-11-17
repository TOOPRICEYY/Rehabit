import XCTest
@testable import RehabitCore

/// Cases found by an adversarial test pass on the check-in code (round 1).
final class CheckInRegressionTests: XCTestCase {
    var zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 0)

    func at(_ text: String) -> Date { GarminClient.localTime(text + ":00", zone: zone)! }
    func model(_ store: Store? = nil) throws -> AppModel {
        AppModel(store: try store ?? Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
    }
    func entry(_ name: String, _ m: AppModel) -> CatalogueExercise { m.library.catalogue.first { $0.name == name }! }
    @discardableResult
    func session(_ m: AppModel, _ name: String = "Single-Leg Extension (Machine)", side: Side = .right, minutes: Double = 30) -> Workout {
        clock.addTimeInterval(-minutes * 60)
        m.startWorkout()
        var s = m.addSet(entry(name, m), side: side)!
        s.reps = 10; s.loadValue = 20
        m.update(s)
        clock.addTimeInterval(minutes * 60)
        m.finishWorkout()
        return m.workouts.first!
    }
    func quad(_ m: AppModel) -> Injury {
        let i = Injury(label: "Quad", side: .right, onset: Day("2026-05-01")!, tissues: ["quads"]); m.save(i); return m.injuries.first { $0.id == i.id }!
    }

    // 1. Editing the end of a workout whose "right after" was answered asks it again.
    func testEditEndReasksAnsweredAfterSession() throws {
        clock = at("2026-11-16 17:00")
        let m = try model(); _ = quad(m)
        var w = session(m)
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 2)
        clock = at("2026-11-16 17:10")
        w.end = at("2026-11-16 17:05")
        m.update(w)
        XCTAssertEqual(m.dueChecks.count, 0, "already answered right-after asked again: \(m.dueChecks.map(\.moment))")
        XCTAssertEqual(m.checks.filter { $0.moment == .afterSession }.count, 1)
    }

    // 2. Session ending just before the morning hour: right-after and next-morning one minute apart.
    func testSmallHoursSessionAsksTwiceWithinFourHours() throws {
        clock = at("2026-11-16 07:59")
        let m = try model(); _ = quad(m)
        session(m)
        let s = m.checks.filter { $0.dueAt < at("2026-11-16 12:00") }
        XCTAssertEqual(s.count, 1, "within 4 h should be one reading: \(s.map(\.moment)) \(s.map(\.dueAt))")
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 2)
        clock = at("2026-11-16 08:01")
        XCTAssertTrue(m.dueChecks.isEmpty, "asked again 2 minutes later: \(m.dueChecks.map(\.moment))")
    }

    // 3. 24h and 48h reminders in the middle of the night.
    func testNightReminders() throws {
        clock = at("2026-11-16 01:00")
        let m = try model(); _ = quad(m)
        session(m)
        var c = Calendar(identifier: .gregorian); c.timeZone = zone
        let night = m.reminderRounds.filter { r in
            let h = c.component(.hour, from: r.fireAt); return h < 7 || h >= 22
        }
        XCTAssertEqual(night.map(\.fireAt), [], "night notifications")
    }

    // 4. A round fires before some of its questions are due, then fires again.
    func testRoundFiresEarlyAndAgain() throws {
        clock = at("2026-11-14 09:15")
        let m = try model()
        let a = Injury(label: "Calf", side: .left, onset: Day("2026-05-01")!, tissues: ["calf"]); m.save(a)
        _ = quad(m)
        session(m)                                     // quad 48h at 11-16 09:15
        clock = at("2026-11-15 22:00")
        let round = try XCTUnwrap(m.reminderRounds.first)
        XCTAssertEqual(round.fireAt, at("2026-11-16 08:00"))
        clock = round.fireAt
        let shown = m.checkInRound.map(\.injury.label)
        XCTAssertEqual(shown.sorted(), round.injuryLabels.sorted(), "notification names injuries the screen does not show")
        m.answer(m.checkInRound.map { (check: $0.check, pain: 1.0, type: PainType?.none, notes: "") })
        clock = at("2026-11-16 08:01")
        let again = m.reminderRounds.first { $0.fireAt < at("2026-11-16 12:00") }
        XCTAssertNil(again, "second notification for the same round: \(String(describing: again?.id))")
    }

    // 5. A flare-up logged hides the open morning follow-up.
    func testFlareHidesOpenFollowUp() throws {
        clock = at("2026-11-16 17:00")
        let m = try model(); let q = quad(m)
        session(m)
        clock = at("2026-11-17 08:10")
        XCTAssertEqual(m.dueChecks.map(\.moment), [.nextMorning])
        m.logPain([(injury: q, pain: 5, type: nil)], context: "stairs")
        XCTAssertEqual(m.dueChecks.map(\.moment), [.nextMorning], "morning follow-up vanished after a flare log")
    }

    // 6. Skip on one device erases an answer given on another.
    func testSkipOverwritesAnswerOnMerge() throws {
        clock = at("2026-11-16 08:05")
        let a = try model(); let q = quad(a)
        let b = try model()
        XCTAssertGreaterThan(b.merge(try XCTUnwrap(a.exportJSON())), 0)
        a.answer(try XCTUnwrap(a.dueChecks.first), pain: 4)
        clock = at("2026-11-16 08:10")
        b.skip(b.dueChecks)
        a.merge(try XCTUnwrap(b.exportJSON())); b.merge(try XCTUnwrap(a.exportJSON()))
        let id = AppModel.dailyCheckID(injuryID: q.id, day: Day("2026-11-16")!)
        XCTAssertEqual(a.checks.first { $0.id == id }?.pain, 4, "answer lost to a skip")
    }

    // 7. Deleting the first of two sessions loses the second session's morning question.
    func testDeleteFirstSessionLosesSecondsMorning() throws {
        clock = at("2026-11-16 10:00")
        let m = try model(); _ = quad(m)
        m.profile.dailyCheckIn = false
        let first = session(m)
        clock = at("2026-11-16 14:00")
        let second = session(m)
        m.deleteWorkout(first)
        let morning = m.checks.filter { $0.workoutID == second.id && $0.dueAt > at("2026-11-17 00:00") && $0.dueAt < at("2026-11-17 12:00") }
        XCTAssertFalse(morning.isEmpty, "second session has no next-morning question after first deleted: \(m.checks.map { ($0.moment, $0.dueAt) })")
    }

    // 8. Negative zero
    func testNegativeZero() throws {
        clock = at("2026-11-16 08:05")
        let m = try model(); _ = quad(m)
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: -0.2)
        let p = try XCTUnwrap(m.checks.first?.pain)
        XCTAssertFalse(p.sign == .minus, "stored -0: \(p)")
    }

    // 9. Spring forward with morningHour 2
    func testSpringForwardMorningHour() throws {
        clock = at("2026-03-07 17:00")
        let m = try model(); _ = quad(m)
        m.profile.morningHour = 2
        session(m)
        let nm = m.checks.first { $0.moment == .nextMorning }
        XCTAssertNotNil(nm, "no next-morning on spring-forward day")
        let daily = m.schedule.morning(of: Day("2026-03-08")!)
        print("DST nextMorning", nm?.dueAt as Any, "daily", daily as Any)
        XCTAssertEqual(nm?.dueAt, daily)
        clock = at("2026-10-31 17:00")
        m.profile.morningHour = 1
        session(m)
        let nm2 = m.checks.filter { $0.moment == .nextMorning }.last
        print("DST fallback", nm2?.dueAt as Any, m.schedule.morning(of: Day("2026-11-01")!) as Any)
        XCTAssertEqual(nm2?.dueAt, m.schedule.morning(of: Day("2026-11-01")!))
    }

    // 10. answering a stale check after update deleted it
    func testStaleAnswerRevivesDeletedCheck() throws {
        clock = at("2026-11-16 17:00")
        let m = try model(); _ = quad(m)
        var w = session(m)
        let stale = try XCTUnwrap(m.dueChecks.first)
        w.end = at("2026-11-16 16:50")
        m.update(w)
        m.answer(stale, pain: 3)
        XCTAssertEqual(m.checks.filter { $0.moment == .afterSession }.count, 1, "two after-session records: \(m.checks.map { ($0.moment, $0.dueAt, $0.isOpen) })")
    }

    func testAnswerAfterInjuryDeletedLeavesOrphan() throws {
        clock = at("2026-11-16 08:05")
        let m = try model(); let q = quad(m)
        let c = try XCTUnwrap(m.dueChecks.first)
        m.deleteInjury(id: q.id)
        m.answer(c, pain: 3)
        XCTAssertTrue(m.checks.isEmpty, "orphan check stored for deleted injury")
    }

    // 11. settling counts a flare as a question asked
    func testSettlingAskedCountsFlare() throws {
        clock = at("2026-11-16 08:05")
        let m = try model(); let q = quad(m)
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 1)
        clock = at("2026-11-16 17:00")
        let w = session(m)
        let asked0 = try XCTUnwrap(m.settling(for: w).first).asked
        clock = at("2026-11-16 19:00")
        m.logPain([(injury: q, pain: 4, type: nil)])
        let s = try XCTUnwrap(m.settling(for: w).first)
        XCTAssertEqual(s.asked, asked0, "flare counted as a question asked")
    }

    // 12. baseline taken from a flare just before the session
    func testBaselineFromFlare() throws {
        clock = at("2026-11-16 08:05")
        let m = try model(); let q = quad(m)
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 1)
        clock = at("2026-11-16 15:00")
        m.logPain([(injury: q, pain: 7, type: nil)])
        clock = at("2026-11-16 17:00")
        let w = session(m)
        XCTAssertEqual(try XCTUnwrap(m.settling(for: w).first).baseline, 1, "baseline is a flare-up")
    }

    // 13. unchanged copies a flare value
    func testUnchangedCopiesFlare() throws {
        clock = at("2026-11-16 08:05")
        let m = try model(); let q = quad(m)
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 1)
        clock = at("2026-11-16 21:00")
        m.logPain([(injury: q, pain: 8, type: nil)])
        clock = at("2026-11-17 08:05")
        m.answerUnchanged(m.dueChecks)
        XCTAssertEqual(m.checks.last { $0.source == PainCheck.unchanged }?.pain, 1, "unchanged copied flare")
    }


    // 15. Zone change: answered daily in Tokyo, then phone in Detroit the same calendar day
    func testZoneChangeWest() throws {
        let store = try Store(path: ":memory:")
        zone = TimeZone(identifier: "Asia/Tokyo")!
        clock = at("2026-11-17 08:05")
        let tokyo = try model(store); _ = quad(tokyo)
        tokyo.answer(try XCTUnwrap(tokyo.dueChecks.first), pain: 2)
        zone = TimeZone(identifier: "America/Detroit")!
        clock = at("2026-11-17 08:05")
        let det = try model(store)
        XCTAssertEqual(det.dueChecks.count, 1, "Detroit morning of the 17th not asked (answered in Tokyo ~22 h earlier)")
    }
}
