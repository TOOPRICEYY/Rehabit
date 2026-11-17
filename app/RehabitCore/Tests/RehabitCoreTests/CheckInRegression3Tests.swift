import XCTest
@testable import RehabitCore

/// Cases found by an adversarial test pass on the check-in code (round 1).
final class CheckInRegression3Tests: XCTestCase {
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

    // An edit after the morning answer stores a second, open next-morning question for the same morning.
    func testEditEndDuplicatesAnsweredMorning() throws {
        clock = at("2026-11-16 17:00")
        let m = try model(); _ = quad(m)
        var w = session(m)
        clock = at("2026-11-17 08:30")
        m.answer(m.dueChecks[0], pain: 2)
        w.end = at("2026-11-16 17:20")
        m.update(w)
        let mornings = m.checks.filter { $0.moment == .nextMorning }
        XCTAssertEqual(mornings.count, 1, "\(mornings.map { ($0.dueAt, $0.isOpen) })")
        clock = at("2026-11-19 08:00")
        let s = try XCTUnwrap(m.settling(for: m.workouts[0]).first)
        print("ASKED", s.asked, s.readings.count)
    }

    // "Unchanged" copies a reading from weeks ago.
    func testUnchangedNoAgeLimit() throws {
        clock = at("2026-10-01 08:05")
        let m = try model(); _ = quad(m)
        m.answer(m.dueChecks[0], pain: 6)
        clock = at("2026-11-16 08:05")
        let item = try XCTUnwrap(m.checkInRound.first)
        XCTAssertEqual(item.last?.pain, 6)
        m.answerUnchanged([item.check])
        XCTAssertNil(m.checks.first { $0.source == PainCheck.unchanged }, "copied a 46-day-old reading as today's")
    }

    // The morning answered during the session (after it started) is not taken as the baseline.
    func testBaselineAnsweredDuringSession() throws {
        clock = at("2026-11-16 09:00")
        let m = try model(); _ = quad(m)
        m.startWorkout()
        var s = m.addSet(entry("Single-Leg Extension (Machine)", m), side: .right)!
        s.reps = 10; s.loadValue = 20; m.update(s)
        clock = at("2026-11-16 09:05")
        m.answer(m.dueChecks[0], pain: 1)          // the 8:00 morning question, answered at 9:05
        clock = at("2026-11-16 10:00")
        m.finishWorkout()
        let st = try XCTUnwrap(m.settling(for: m.workouts[0]).first)
        XCTAssertEqual(st.baseline, 1, "the morning reading is neither baseline nor reading")
        XCTAssertFalse(st.readings.contains { $0.moment == .baseline })
    }

    // Overlapping sessions: the second session's right-after reading is counted in the first's settling.
    func testSettlingOverlap() throws {
        clock = at("2026-11-16 08:05")
        let m = try model(); _ = quad(m)
        m.answer(m.dueChecks[0], pain: 1)
        clock = at("2026-11-16 10:00"); let a = session(m)
        m.answer(m.dueChecks[0], pain: 1)
        clock = at("2026-11-16 14:00"); session(m)
        m.answer(m.dueChecks[0], pain: 5)
        let st = try XCTUnwrap(m.settling(for: a).first)
        print("OVERLAP peak", st.summary?.peak as Any)
    }
}
