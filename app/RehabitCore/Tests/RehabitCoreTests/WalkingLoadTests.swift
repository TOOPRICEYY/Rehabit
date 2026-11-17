import XCTest
@testable import RehabitCore

final class WalkingLoadTests: XCTestCase {
    struct Steps: HealthSource {
        var name = "watch"
        let values: [Day: Double]
        func requestAccess() async throws -> Bool { true }
        func dailyMetrics(from: Day, through: Day) async throws -> [DailyMetric] {
            values.map { DailyMetric(day: $0.key, metric: MetricName.steps, value: $0.value, source: name) }
        }
    }

    func testStepsBecomeLegLoadWithGapsAndTheStartFilled() {
        let ledger = Ledger()
        let start = Day("2026-10-01")!
        var steps: [Day: Double] = [:]
        for i in 0..<20 where i != 10 { steps[start.adding(i)] = 8000 }   // day 10 off the wrist
        steps[start.adding(20)] = 16000
        let walks = ledger.walkingSets(steps: steps)
        XCTAssertEqual(walks.first?.day, start.adding(-28))              // warm-up before the first reading
        XCTAssertEqual(walks.last?.day, start.adding(20))
        XCTAssertEqual(walks.count, 49)
        let reps = Dictionary(uniqueKeysWithValues: walks.map { ($0.day, $0.reps!) })
        XCTAssertEqual(reps[start.adding(-5)], 40)                       // 8,000 steps: 4,000 a leg, 40 reps
        XCTAssertEqual(reps[start.adding(10)], 40)                       // the gap takes the usual day
        XCTAssertEqual(reps[start.adding(20)], 80)
        XCTAssertTrue(walks.allSatisfy { $0.side == .both && $0.pattern == "walking" })

        // A steady walker's calf load does not change; a doubled day shows.
        let days = ledger.tissueDays(walks)
        let calf = days.filter { $0.tissue == "calf" && $0.side == .left }
        XCTAssertEqual(calf.first { $0.day == start.adding(10) }?.dose ?? 0, 40, accuracy: 1e-9)
        XCTAssertEqual(calf.first { $0.day == start.adding(20) }?.dose ?? 0, 80, accuracy: 1e-9)
        let quads = days.first { $0.tissue == "quads" && $0.day == start.adding(5) }
        XCTAssertEqual(quads?.dose ?? 0, 12, accuracy: 1e-9)             // a small share of the thigh

        var off = LedgerSettings(); off.countSteps = false
        XCTAssertTrue(Ledger(settings: off).walkingSets(steps: steps).isEmpty)
        XCTAssertTrue(ledger.walkingSets(steps: [start: 0]).isEmpty)     // a zero is a watch not worn
    }

    @MainActor
    func testTheLoadTabCountsStepsFromTheLargestSource() async throws {
        let zone = TimeZone(identifier: "America/Detroit")!
        let now = Date(timeIntervalSince1970: 1_795_000_000)              // 2026-11-17
        let m = AppModel(store: try Store(path: ":memory:"), zone: zone, now: { now })
        let today = Day(now, in: zone)
        var watch: [Day: Double] = [:], phone: [Day: Double] = [:]
        for i in 0..<40 { watch[today.adding(-i)] = 6000; phone[today.adding(-i)] = 5000 }
        _ = await m.importHealth(from: Steps(values: watch))
        _ = await m.importHealth(from: Steps(name: "phone", values: phone))
        let calf = try XCTUnwrap(m.tissueWeeks().first { $0.tissue.id == "calf" && $0.side == .right })
        XCTAssertEqual(calf.week, 7 * 30, accuracy: 1e-6)                // 6,000 steps, never 11,000
        XCTAssertEqual(calf.ratio ?? 0, 1, accuracy: 1e-6)
        let detail = m.tissueDetail("calf", side: .left)
        XCTAssertEqual(detail.contributions.map(\.exercise), [Ledger.walkingName])
        XCTAssertNil(m.lastError)
    }
}
