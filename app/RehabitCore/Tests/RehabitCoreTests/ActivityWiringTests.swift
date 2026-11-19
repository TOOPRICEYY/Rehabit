import XCTest
@testable import RehabitCore

/// Sessions with no sets, imported from the watch, reach the Load tab once each.
final class ActivityWiringTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!

    @MainActor
    func testARideAddsQuadLoadAndASaunaNone() throws {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let m = AppModel(store: try Store(path: ":memory:"), zone: zone, now: { now })
        let ride = now.addingTimeInterval(-2 * 86_400), sauna = now.addingTimeInterval(-86_400)
        m.importWorkouts([
            ImportedWorkout(sourceID: "1", title: "Evening Ride", start: ride, end: ride.addingTimeInterval(3600),
                            activity: ActivitySummary(type: "road_biking", averageHeartRate: 140, maxHeartRate: 175)),
            ImportedWorkout(sourceID: "2", title: "Sauna", start: sauna, end: sauna.addingTimeInterval(1200),
                            activity: ActivitySummary(type: "sauna", averageHeartRate: 100)),
        ], source: GarminSource.sourceName, inferSide: false)
        XCTAssertEqual(m.workouts.count, 2)

        let rideWorkout = try XCTUnwrap(m.workouts.first { $0.title == "Evening Ride" })
        let rideLoad = try XCTUnwrap(m.activityLoad(for: rideWorkout))
        XCTAssertEqual(rideLoad.pattern, "cycling")
        XCTAssertEqual(rideLoad.tissue?.id, "quads")
        XCTAssertGreaterThan(rideLoad.effectiveReps, 0)
        let saunaWorkout = try XCTUnwrap(m.workouts.first { $0.title == "Sauna" })
        XCTAssertEqual(m.activityLoad(for: saunaWorkout)?.effectiveReps, 0)
        XCTAssertNil(m.activityLoad(for: saunaWorkout)?.pattern)

        // On the Load tab: quads carry the ride, once; nothing comes from the sauna.
        let quads = try XCTUnwrap(m.tissueWeeks().first { $0.tissue.id == "quads" && $0.side == .left })
        XCTAssertEqual(quads.week, rideLoad.effectiveReps, accuracy: 1e-6)
        XCTAssertEqual(m.tissueDetail("quads", side: .right).contributions.map(\.exercise), ["Cycling"])
        // Reading the same sessions again adds nothing and counts nothing twice.
        m.importWorkouts([ImportedWorkout(sourceID: "1", title: "Evening Ride", start: ride, end: ride.addingTimeInterval(3600),
                                          activity: ActivitySummary(type: "road_biking", averageHeartRate: 140))],
                         source: GarminSource.sourceName, inferSide: false)
        let again = try XCTUnwrap(m.tissueWeeks().first { $0.tissue.id == "quads" && $0.side == .left })
        XCTAssertEqual(again.week, quads.week, accuracy: 1e-9)
    }
}
