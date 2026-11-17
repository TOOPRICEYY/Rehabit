import XCTest
@testable import RehabitCore

final class RecoveryTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 1_790_000_000)

    struct Fixed: HealthSource {
        let name = "test"
        let metrics: [DailyMetric]
        func requestAccess() async throws -> Bool { true }
        func dailyMetrics(from: Day, through: Day) async throws -> [DailyMetric] { metrics }
    }

    func testAWeekIsReadAgainstTheFourBeforeAndThinDataSaysNothing() async throws {
        let m = AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
        let today = Day(clock, in: zone)
        var metrics: [DailyMetric] = []
        for back in 0..<35 {
            let day = today.adding(-back)
            // HRV: 60 in the usual weeks with a little spread, 50 this week. Two devices, kept apart.
            metrics.append(DailyMetric(day: day, metric: MetricName.hrv, value: back < 7 ? 50 : 58 + Double(back % 5), source: "garmin"))
            if back < 10 { metrics.append(DailyMetric(day: day, metric: MetricName.hrv, value: 120, source: "other_watch")) }
            // Steps from phone and watch: the larger of the two each day.
            metrics.append(DailyMetric(day: day, metric: MetricName.steps, value: 8000, source: "apple_health"))
            metrics.append(DailyMetric(day: day, metric: MetricName.steps, value: back < 7 ? 12_000 : 9000, source: "garmin"))
            // Sleep: only three nights this week, so nothing is said.
            if back >= 4 { metrics.append(DailyMetric(day: day, metric: MetricName.sleepMinutes, value: 430, source: "garmin")) }
        }
        let stored = await m.importHealth(from: Fixed(metrics: metrics))
        XCTAssertEqual(stored, metrics.count)
        let readings = m.recoveryReadings()
        XCTAssertEqual(readings.map(\.metric), [MetricName.hrv, MetricName.steps])
        let hrv = try XCTUnwrap(readings.first)
        XCTAssertEqual(hrv.source, "garmin")
        XCTAssertEqual(hrv.recentMean, 50); XCTAssertEqual(hrv.recentDays, 7); XCTAssertEqual(hrv.usualDays, 28)
        XCTAssertEqual(hrv.usualMean, 60, accuracy: 0.2)
        XCTAssertEqual(hrv.daysBelow, 0); XCTAssertTrue(hrv.isOutsideUsual)
        XCTAssertEqual(hrv.sentence, "Overnight HRV: 50 ms over the last 7 days (7 with a value), 60 ms over the 28 days before (28). Lower than every one of those days.")
        let steps = readings[1]
        XCTAssertEqual(steps.recentMean, 12_000); XCTAssertEqual(steps.usualMean, 9000)
        XCTAssertEqual(steps.text(steps.recentMean), "12,000")
        XCTAssertEqual(steps.daysBelow, 28)
        // A week earlier there were no 28 days before it: nothing is said.
        XCTAssertTrue(m.recoveryReadings(on: today.adding(-25)).isEmpty)
        XCTAssertEqual(RecoveryReading(metric: MetricName.sleepMinutes, source: "x", latest: 0, latestDay: today, recentMean: 430,
                                       recentDays: 7, usualMean: 430, usualDays: 28, usualLow: 0, usualHigh: 0, daysBelow: 0).text(430), "7 h 10 min")
    }
}
