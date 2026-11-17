import XCTest
@testable import RehabitCore

final class BodyweightTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 1_790_000_000)

    func testAWeightEnteredTodayDoesNotRewriteWhatAPushUpWeighedBefore() throws {
        let m = AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
        let today = Day(clock, in: zone)
        // No readings: the profile's weight stands for every day, as before.
        m.profile.bodyweightKg = 80
        XCTAssertEqual(m.bodyweightKg(on: today.adding(-100)), 80)

        m.logBodyweight(80, on: today.adding(-30))
        m.startWorkout()
        var push = try XCTUnwrap(m.addSet(try XCTUnwrap(m.library.catalogue.first { $0.name == "Push-Up" })))
        push.reps = 10
        m.update(push)
        m.finishWorkout()
        let before = m.exerciseHistory("Push-Up").first?.sets.first.flatMap { _ in m.records(for: "Push-Up", side: .both) }
        let share = try XCTUnwrap(m.library.pattern("push_up")?.bodyweightShare)

        clock.addTimeInterval(20 * 86_400)
        m.logBodyweight(70)                                               // twenty days on, ten kilograms lighter
        XCTAssertEqual(m.profile.bodyweightKg, 70)
        XCTAssertEqual(m.bodyweightKg(on: today), 80)                     // the day of the push-ups keeps its weight
        XCTAssertEqual(m.bodyweightKg(on: today.adding(20)), 70)
        XCTAssertEqual(m.bodyweightKg(on: today.adding(-60)), 80)         // before the first reading: the first
        XCTAssertEqual(m.bodyweightHistory.map(\.kg), [80, 70])
        let line = m.timeline(for: Injury(label: "Pec", side: .both, onset: today, tissues: ["pec_major"]), days: 30)
        XCTAssertEqual(line.first { $0.day == today }?.volumeKg ?? 0, 80 * share * 10, accuracy: 0.001)
        _ = before

        // A device's value for a day gives way to one typed in; an unusable number is refused.
        m.logBodyweight(.nan); XCTAssertNotNil(m.lastError)
        m.logBodyweight(-5); XCTAssertEqual(m.bodyweightHistory.count, 2)
    }
}
