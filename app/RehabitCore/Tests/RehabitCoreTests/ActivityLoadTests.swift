import XCTest
@testable import RehabitCore

/// Recorded activities as tissue load. The numbers are the service's
/// (`tests/test_activity_load.py`); the shared fixture holds the two together.
final class ActivityLoadTests: XCTestCase {
    let day = Day("2026-03-02")!

    func testTypesMapToAPatternOrToNothing() {
        let cases: [(String?, String?, String?)] = [
            ("cycling", "Plainfield Cycling", "cycling"), ("indoor_cycling", nil, "cycling"),
            ("indoor_rowing", "Indoor Rowing", "rowing"), ("treadmill_running", nil, "running"),
            ("lap_swimming", nil, "swimming"), ("hiking", nil, "hiking"), ("yoga", nil, "yoga"),
            ("pickleball", nil, "pickleball"), ("tennis", nil, "court_sports"), ("walking", "Walk", nil), ("treadmill_walking", nil, nil),
            ("strength_training", "Strength", nil), ("indoor_cardio", "Sauna", nil),
            ("indoor_cardio", "Cardio", nil), ("indoor_cardio", "Rowing", "rowing"), (nil, nil, nil),
            ("hand_cycling", nil, nil), ("motorcycling", nil, nil), ("wheelchair_push_run", nil, nil),
            ("backcountry_skiing", nil, nil), ("ice_hockey", nil, nil), ("e_bike_fitness", nil, "cycling"),
            ("floor_climbing", nil, "stair_climbing"), ("rucking", nil, "hiking"), ("hiit", nil, "hiit"),
            ("indoor_cardio", "Stationary bike", "cycling"), ("indoor_cardio", "Peloton", "cycling"),
        ]
        for (type, name, want) in cases {
            XCTAssertEqual(ActivityMatcher.pattern(type: type, name: name), want, "\(type ?? "-") \(name ?? "-")")
        }
    }

    func testActivityPatternsAreNotOfferedForSets() {
        let library = Library.standard
        XCTAssertEqual(library.activityRates["cycling"], 0.25)
        XCTAssertTrue(library.isActivity("rowing"))
        XCTAssertFalse(library.isActivity("row"))
        XCTAssertFalse(library.exercisePatterns.contains { $0.id == "cycling" || $0.id == "running" })
        XCTAssertTrue(library.exercisePatterns.contains { $0.id == "row" })
    }

    func testLibraryRoundTripKeepsTheRates() throws {
        let copy = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(Library.standard))
        XCTAssertEqual(copy.activityRates, Library.standard.activityRates)
        XCTAssertEqual(copy.activityMatchers, Library.standard.activityMatchers)
    }

    func testHeartRateReserveScalesLinearlyAndIsClamped() {
        let ledger = Ledger()
        XCTAssertEqual(ledger.activityIntensity(averageHR: 115, restingHR: 50, maxHR: 180), 1, accuracy: 1e-9)
        XCTAssertEqual(ledger.activityIntensity(averageHR: 147.5, restingHR: 50, maxHR: 180), 1.5, accuracy: 1e-9)
        XCTAssertEqual(ledger.activityIntensity(averageHR: 60, restingHR: 50, maxHR: 180), 0.5)
        XCTAssertEqual(ledger.activityIntensity(averageHR: 200, restingHR: 50, maxHR: 180), 2)
        XCTAssertEqual(ledger.activityIntensity(averageHR: nil, restingHR: 50, maxHR: 180), 1)
        XCTAssertEqual(ledger.activityIntensity(averageHR: 120, restingHR: nil, maxHR: 180), 1)
        XCTAssertEqual(ledger.activityIntensity(averageHR: 120, restingHR: 50, maxHR: nil), 1)
        XCTAssertEqual(ledger.activityIntensity(averageHR: 120, restingHR: 90, maxHR: 110), 1)
        XCTAssertEqual(ledger.activityIntensity(averageHR: .nan, restingHR: 50, maxHR: 180), 1)
        XCTAssertNil(ledger.observedMaxHR([180, 170, 160, 150]))
        XCTAssertEqual(ledger.observedMaxHR([180, 170, 160, 150, 140, .nan, 0]), 180)
    }

    func testMinutesTimesRateOnBothSidesWithNoSetsCounted() {
        let ledger = Ledger()
        let ride = LedgerActivity(day: day, type: "cycling", name: "Ride", minutes: 40, averageHR: nil)
        let days = ledger.tissueDays(ledger.activitySets([ride], restingHR: [:], maxHR: nil))
        let quads = days.filter { $0.tissue == "quads" && $0.day == day }
        XCTAssertEqual(quads.count, 2)
        for q in quads {
            XCTAssertEqual(q.dose, 10, accuracy: 1e-9)
            XCTAssertEqual(q.sets, 0)
            XCTAssertEqual(q.reps, 0)
        }
        XCTAssertFalse(days.contains { $0.tissue == "pec_major" })
    }

    func testUsualRestingRateAndIntensityChangeTheDose() {
        let ledger = Ledger()
        var resting: [Day: Double] = [:]
        for i in 0...28 { resting[day.adding(-i)] = 50 }
        resting[day.adding(-29)] = 90                      // outside the 28 days
        XCTAssertEqual(Ledger.usualRestingHR(resting, on: day), 50)
        let row = LedgerActivity(day: day, type: "indoor_rowing", name: nil, minutes: 10, averageHR: 147.5)
        let set = ledger.activitySets([row], restingHR: resting, maxHR: 180)
        XCTAssertEqual(set.first?.reps ?? 0, 10 * 0.65 * 1.5, accuracy: 1e-9)
        XCTAssertEqual(ledger.activitySets([row], restingHR: resting, maxHR: nil).first?.reps ?? 0, 6.5, accuracy: 1e-9)
    }

    func testUnknownCountedOrEmptyActivitiesAddNothing() {
        var ledger = Ledger()
        let none = [
            LedgerActivity(day: day, type: "indoor_cardio", name: "Sauna", minutes: 30, averageHR: 140),
            LedgerActivity(day: day, type: "walking", name: "Walk", minutes: 60, averageHR: nil),
            LedgerActivity(day: day, type: "running", name: nil, minutes: nil, averageHR: nil),
            LedgerActivity(day: day, type: "running", name: nil, minutes: -5, averageHR: nil),
            LedgerActivity(day: day, type: "running", name: nil, minutes: .infinity, averageHR: nil),
        ]
        XCTAssertTrue(ledger.activitySets(none, restingHR: [:], maxHR: nil).isEmpty)
        let long = LedgerActivity(day: day, type: "cycling", name: nil, minutes: 100_000, averageHR: nil)
        XCTAssertEqual(ledger.activitySets([long], restingHR: [:], maxHR: nil).first?.reps ?? 0, 150, accuracy: 1e-9)
        ledger.settings.countActivities = false
        XCTAssertTrue(ledger.activitySets([long], restingHR: [:], maxHR: nil).isEmpty)
    }

    func testThePersonsAnswerWinsOverTheType() {
        let ledger = Ledger()
        let bike = LedgerActivity(day: day, type: "indoor_cardio", name: "Cardio", minutes: 20, averageHR: nil, countsAs: "cycling")
        let none = LedgerActivity(day: day, type: "cycling", name: "Ride", minutes: 30, averageHR: nil, countsAs: "none")
        XCTAssertEqual(ledger.activityPattern(bike), "cycling")
        XCTAssertNil(ledger.activityPattern(none))
        let sets = ledger.activitySets([bike, none], restingHR: [:], maxHR: nil)
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets.first?.reps ?? 0, 5, accuracy: 1e-9)
    }
}
