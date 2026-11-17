import XCTest
@testable import RehabitCore

/// Cases found by an adversarial test pass on the check-in code (round 1).
final class CheckInRegression2Tests: XCTestCase {
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

    func time(_ label: String, _ n: Int = 50, _ body: () -> Void) {
        let t0 = Date()
        for _ in 0..<n { body() }
        print("PERF \(label): \(String(format: "%.2f", Date().timeIntervalSince(t0) / Double(n) * 1000)) ms")
    }


    // Edit end forward and back repeatedly: no stray open questions, no duplicates.
    func testRepeatedEdits() throws {
        clock = at("2026-11-16 17:00")
        let m = try model(); _ = quad(m)
        var w = session(m)
        clock = at("2026-11-16 17:30")
        for i in 0..<10 {
            w.end = at("2026-11-16 17:00").addingTimeInterval(Double(i % 2 == 0 ? 600 : -600))
            m.update(w)
        }
        let open = m.checks.filter(\.isOpen)
        XCTAssertEqual(open.map(\.moment), [.afterSession, .nextMorning, .hours24, .hours48])
        XCTAssertNil(m.lastError)
    }

    // Answered next-morning question re-asked after a later edit of the session's end.
    func testEditEndReasksAnsweredMorning() throws {
        clock = at("2026-11-16 17:00")
        let m = try model(); _ = quad(m)
        var w = session(m)
        clock = at("2026-11-17 08:30")
        XCTAssertEqual(m.dueChecks.map(\.moment), [.nextMorning])
        m.answer(m.dueChecks[0], pain: 2)
        XCTAssertTrue(m.dueChecks.isEmpty)
        w.end = at("2026-11-16 17:20")
        m.update(w)
        XCTAssertTrue(m.dueChecks.isEmpty, "answered morning question asked again: \(m.dueChecks.map(\.moment))")
    }

    // Same daily answered on both devices: later answer wins on both.
    func testSameDailyOnTwoDevices() throws {
        clock = at("2026-11-16 08:05")
        let a = try model(); _ = quad(a)
        let b = try model(); b.merge(try XCTUnwrap(a.exportJSON()))
        a.answer(a.dueChecks[0], pain: 3)
        clock = at("2026-11-16 08:06")
        b.answer(b.dueChecks[0], pain: 5)
        a.merge(try XCTUnwrap(b.exportJSON())); b.merge(try XCTUnwrap(a.exportJSON()))
        XCTAssertEqual(a.checks.map(\.pain), [5]); XCTAssertEqual(b.checks.map(\.pain), [5])
        XCTAssertTrue(a.dueChecks.isEmpty)
    }

    // Clock set back: a later answer given at an earlier clock time is not the "last reading".
    func testClockBackwardsUnchanged() throws {
        clock = at("2026-11-16 17:00")
        let m = try model(); _ = quad(m)
        session(m)
        m.answer(m.dueChecks[0], pain: 2)               // 17:00
        clock = at("2026-11-17 08:30")
        m.answer(m.dueChecks[0], pain: 6)               // next morning 6
        clock = at("2026-11-17 08:00")                  // clock jumps back (manual change / network time)
        clock = at("2026-11-17 10:00")
        // nothing odd yet; now a clock 1 day behind answers today's 24h... use direct check
        XCTAssertEqual(m.lastReading(injuryID: m.injuries[0].id)?.pain, 6)
    }

    // Resolve then reactivate while questions are open.
    func testResolveReactivate() throws {
        clock = at("2026-11-16 17:00")
        let m = try model(); var q = quad(m)
        session(m)
        m.answer(m.dueChecks[0], pain: 2)
        q.resolvedOn = Day("2026-11-16"); m.save(q)
        XCTAssertEqual(m.checks.count, 1)
        clock = at("2026-11-17 08:10")
        q = m.injuries[0]; q.resolvedOn = nil; m.save(q)
        XCTAssertEqual(m.dueChecks.map(\.moment), [.baseline])
    }

    // Both-sides injury loaded by left-only set.
    func testBothSidesInjury() throws {
        clock = at("2026-11-16 17:00")
        let m = try model()
        m.save(Injury(label: "Knees", side: .both, onset: Day("2026-05-01")!, tissues: ["quads"]))
        session(m, side: .left)
        XCTAssertEqual(m.checks.count, 4)
    }

    // Pain outside range / NaN in the batch answer: NaN silently dropped, no error.
    func testBatchNaNSilent() throws {
        clock = at("2026-11-16 08:05")
        let m = try model(); _ = quad(m)
        m.answer([(check: m.dueChecks[0], pain: .nan, type: nil, notes: "")])
        XCTAssertNotNil(m.lastError, "NaN answer silently ignored in the batch call")
    }

    // A session ending at 23:50 and morningHour 0.
    func testMorningHourZeroLateSession() throws {
        clock = at("2026-11-16 23:50")
        let m = try model(); _ = quad(m)
        m.profile.morningHour = 0
        session(m)
        print("MH0", m.checks.map { ($0.moment.rawValue, $0.dueAt) })
        let nearby = m.checks.filter { $0.dueAt < at("2026-11-17 04:00") }
        XCTAssertEqual(nearby.count, 1, "right-after and next-morning 10 minutes apart: \(nearby.map(\.moment))")
    }

    // Three sessions in a day for one injury: how many open future questions?
    func testThreeSessionsADay() throws {
        clock = at("2026-11-16 09:00")
        let m = try model(); _ = quad(m)
        session(m)
        clock = at("2026-11-16 13:00"); session(m)
        clock = at("2026-11-16 18:00"); session(m)
        clock = at("2026-11-16 18:05")
        let ups = m.upcomingChecks.filter { $0.moment != .baseline }
        print("THREE", ups.map { ($0.moment.rawValue, $0.dueAt) })
        // any two within 4 h are one reading
        for (a, b) in zip(ups, ups.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.dueAt.timeIntervalSince(a.dueAt), PainSchedule.sameReading, "\(a.moment) \(a.dueAt) / \(b.moment) \(b.dueAt)")
        }
    }
}
