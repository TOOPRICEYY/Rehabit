import XCTest
@testable import RehabitCore

/// Sessions with no sets, imported from the watch, reach the Load tab once each.
final class ActivityWiringTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!

    @MainActor
    func testARideAddsQuadLoadAndASaunaNone() async throws {
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

    /// Every kind offered can be chosen and is read back as that kind.
    @MainActor
    func testEveryKindCanBeChosen() throws {
        let m = AppModel(store: try Store(path: ":memory:"), zone: zone, now: { Date(timeIntervalSince1970: 1_795_000_000) })
        XCTAssertFalse(m.activityKinds.isEmpty)
        for kind in m.activityKinds {
            let word = AppModel.typeWords[kind.id] ?? kind.id.replacingOccurrences(of: "_", with: " ")
            XCTAssertEqual(ActivityMatcher.pattern(type: word, name: nil), kind.id, kind.id)
        }
    }

    /// Garmin's "Cardio" says nothing of the machine: the person says it was the
    /// bike, for one session or all of them, and can take it out of load.
    @MainActor
    func testCardioCountedAsTheBikeForAllSessionsOfThatName() throws {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let m = AppModel(store: try Store(path: ":memory:"), zone: zone, now: { now })
        let a = now.addingTimeInterval(-3 * 86_400), b = now.addingTimeInterval(-86_400)
        m.importWorkouts([
            ImportedWorkout(sourceID: "a", title: "Cardio", start: a, end: a.addingTimeInterval(1800),
                            activity: ActivitySummary(type: "indoor_cardio", averageHeartRate: 140, steps: 40)),
            ImportedWorkout(sourceID: "b", title: "Cardio", start: b, end: b.addingTimeInterval(1200),
                            activity: ActivitySummary(type: "indoor_cardio", averageHeartRate: 130, steps: 30)),
            ImportedWorkout(sourceID: "c", title: "Sauna", start: b, end: b.addingTimeInterval(900),
                            activity: ActivitySummary(type: "indoor_cardio")),
        ], source: GarminSource.sourceName, inferSide: false)
        let first = try XCTUnwrap(m.workouts.first { $0.title == "Cardio" && $0.start == a })
        XCTAssertEqual(m.activityLoad(for: first)?.effectiveReps, 0)          // unknown on its own
        XCTAssertEqual(m.sessionsLike(first), 2)                             // the sauna has another name

        m.setActivityCountsAs("cycling", for: first, sameName: true)
        let cardio = m.workouts.filter { $0.title == "Cardio" }
        XCTAssertTrue(cardio.allSatisfy { $0.activity?.countsAs == "cycling" })
        XCTAssertNil(m.workouts.first { $0.title == "Sauna" }?.activity?.countsAs)
        for w in cardio {
            let load = try XCTUnwrap(m.activityLoad(for: w))
            XCTAssertEqual(load.pattern, "cycling"); XCTAssertGreaterThan(load.effectiveReps, 0)
        }
        XCTAssertGreaterThan(m.tissueWeeks().first { $0.tissue.id == "quads" && $0.side == .left }?.week ?? 0, 0)

        // One session taken out of load; the other stays.
        let one = try XCTUnwrap(m.workouts.first { $0.title == "Cardio" && $0.start == b })
        m.setActivityCountsAs(AppModel.notCounted, for: one, sameName: false)
        XCTAssertNil(m.activityLoad(for: try XCTUnwrap(m.workouts.first { $0.title == "Cardio" && $0.start == b })))
        XCTAssertNotNil(m.activityLoad(for: try XCTUnwrap(m.workouts.first { $0.title == "Cardio" && $0.start == a })))
        // Back to the watch's own type.
        m.setActivityCountsAs(nil, for: first, sameName: true)
        XCTAssertTrue(m.workouts.filter { $0.title == "Cardio" }.allSatisfy { $0.activity?.countsAs == nil })
    }
}
