import XCTest
@testable import RehabitCore

final class InjuryReportTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 0)

    func at(_ text: String) -> Date { GarminClient.localTime(text + ":00", zone: zone)! }
    func model() throws -> AppModel {
        AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
    }

    /// A finished session of single-leg extensions ending at the clock.
    @discardableResult
    func session(_ m: AppModel, right: Double, left: Double? = nil, pain: Double? = nil) throws -> Workout {
        let entry = try XCTUnwrap(m.library.catalogue.first { $0.name == "Single-Leg Extension (Machine)" })
        clock.addTimeInterval(-1800)
        m.startWorkout()
        var r = try XCTUnwrap(m.addSet(entry, side: .right))
        r.loadValue = right; r.reps = 10; r.pain = pain
        m.update(r)
        if let left {
            var l = try XCTUnwrap(m.addSet(entry, side: .left))
            l.loadValue = left; l.reps = 10
            m.update(l)
        }
        clock.addTimeInterval(1800)
        m.finishWorkout()
        return m.workouts[0]
    }

    func testTimelineJoinsLoadPainAndFlaresByDay() throws {
        clock = at("2026-11-02 08:05")
        let m = try model()
        m.profile.unit = .lb
        let quad = Injury(label: "Right quad strain", side: .right, onset: Day("2026-05-03")!, onsetPrecision: .week,
                          tissues: ["quads"], mechanism: "Sprint")
        m.save(quad)
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 1)                 // Monday morning: 1
        clock = at("2026-11-02 17:00")
        try session(m, right: 20, left: 60, pain: 2)
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 1.5)               // right after
        clock = at("2026-11-03 08:10")
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 3)                 // next morning: up 2
        clock = at("2026-11-03 13:00")
        m.logPain([(injury: quad, pain: 6, type: PainType.sharp)], context: "stairs")
        clock = at("2026-11-04 17:00")
        m.answer(try XCTUnwrap(m.dueChecks.first), pain: 1)                 // 48 hours: settled
        clock = at("2026-11-09 17:00")
        try session(m, right: 25, left: 60)
        clock = at("2026-11-10 09:00")

        let line = m.timeline(for: quad, days: 14)
        XCTAssertEqual(line.count, 14)
        XCTAssertEqual(line.first?.day, Day("2026-10-28")); XCTAssertEqual(line.last?.day, Day("2026-11-10"))
        let monday = try XCTUnwrap(line.first { $0.day == Day("2026-11-02") })
        XCTAssertTrue(monday.trained)
        XCTAssertEqual(monday.load, 10, accuracy: 0.001)                    // ten reps at the usual load, share 1.0
        XCTAssertEqual(monday.otherLoad ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(monday.painLow, 1); XCTAssertEqual(monday.painHigh, 1.5)
        let tuesday = try XCTUnwrap(line.first { $0.day == Day("2026-11-03") })
        XCTAssertFalse(tuesday.trained); XCTAssertEqual(tuesday.load, 0)
        XCTAssertEqual(tuesday.painHigh, 3); XCTAssertEqual(tuesday.flare, 6)       // the flare is not an answer
        // 25 after 20: (25 / 20) squared x 10 reps.
        XCTAssertEqual(line.first { $0.day == Day("2026-11-09") }?.load ?? 0, 15.625, accuracy: 0.001)

        let report = m.report(for: quad, days: 14)
        XCTAssertEqual(report.sessionsLoading, 2)
        XCTAssertEqual(report.sessionsFollowed, 1)                          // the second has no reading before or after
        XCTAssertEqual(report.sessionsRaisedPain, 1); XCTAssertEqual(report.sessionsSettled, 1)
        XCTAssertEqual(report.medianHoursToSettle ?? 0, 48, accuracy: 0.01)
        XCTAssertEqual(report.flares.map(\.pain), [6])
        XCTAssertEqual(report.exercises.map(\.exercise), ["Single-Leg Extension (Machine)"])
        XCTAssertEqual(report.exercises.first?.first, "20 lb x 10"); XCTAssertEqual(report.exercises.first?.latest, "25 lb x 10")
        XCTAssertEqual(report.exercises.first?.other, "60 lb x 10")
        XCTAssertEqual(report.exercises.first?.maxPain, 2)
        XCTAssertEqual(report.weeklyLoad.count, 2); XCTAssertEqual(report.weeklyLoad.reduce(0, +), 25.625, accuracy: 0.001)
        XCTAssertEqual(report.symmetry.first?.ratio ?? 0, 25.0 / 60.0, accuracy: 0.001)
        XCTAssertNil(report.recentPain)                                     // nothing answered since Nov 4 morning
        XCTAssertEqual(report.earlierPain ?? 0, 2, accuracy: 0.001)         // mornings of Nov 2 (1) and Nov 3 (3)

        let text = m.reportText(for: quad, days: 14)
        for needle in ["# Right quad strain", "Right side; Quadriceps. Began around 2026-05-03",
                       "Period: 2026-10-28 to 2026-11-10 (14 days).",
                       "- Flare-ups logged: 1.", "  - 2026-11-03: 6 (stairs; sharp)",
                       "| 2026-11-03 | 10 | 10 |", "| 2026-11-10 | 15.6 | 10 |",
                       "Top set went from 20 lb x 10 to 25 lb x 10. Other side, latest: 60 lb x 10. Highest pain during a set: 2.",
                       "42% of the other side (estimated one-rep max) on 2026-11-09; 33% at the start of the period.",
                       "- Pain rose more than 1 point above the reading before in 1 of 1.",
                       "back within half a point by the last reading: 1, after a median of 48 hours.",
                       "it is not an assessment or advice."] {
            XCTAssertTrue(text.contains(needle), "missing: \(needle)\n\(text)")
        }
        XCTAssertNil(m.lastError)
    }

    func testAnInjuryWithNothingLoggedStillReports() throws {
        clock = at("2026-11-10 21:00")
        let m = try model()
        let both = Injury(label: "Low back", side: .both, onset: Day("2026-11-01")!, tissues: ["erectors"])
        m.save(both)
        let report = m.report(for: both, days: 3)                           // never fewer than a week
        XCTAssertEqual(report.days.count, 7)
        XCTAssertNil(report.weeklyOtherLoad)
        XCTAssertTrue(report.days.allSatisfy { $0.otherLoad == nil && $0.load == 0 })
        let text = m.reportText(for: both)
        XCTAssertTrue(text.contains("Both sides; Spinal erectors."))
        XCTAssertTrue(text.contains("No pain readings in this period."))
        XCTAssertTrue(text.contains("None logged in this period."))
        XCTAssertTrue(text.contains("No session loaded this injury in the period."))
    }
}
