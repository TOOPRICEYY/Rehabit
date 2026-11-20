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
    func testEveryKindCanBeChosen() async throws {
        let m = AppModel(store: try Store(path: ":memory:"), zone: zone, now: { Date(timeIntervalSince1970: 1_795_000_000) })
        XCTAssertFalse(m.activityKinds.isEmpty)
        let ledger = Ledger()
        for kind in m.activityKinds {
            let chosen = LedgerActivity(day: Day("2026-11-10")!, type: "indoor_cardio", name: "Cardio", minutes: 30,
                                        averageHR: nil, countsAs: kind.id)
            XCTAssertEqual(ledger.activityPattern(chosen), kind.id, kind.id)
        }
    }

    /// Garmin's "Cardio" says nothing of the machine: the person says it was the
    /// bike, for one session or all of them, and can take it out of load.
    @MainActor
    func testCardioCountedAsTheBikeForAllSessionsOfThatName() async throws {
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
        XCTAssertEqual(m.activityLoad(for: try XCTUnwrap(m.workouts.first { $0.title == "Cardio" && $0.start == b }))?.effectiveReps, 0)
        XCTAssertNotNil(m.activityLoad(for: try XCTUnwrap(m.workouts.first { $0.title == "Cardio" && $0.start == a })))
        // Back to the watch's own type.
        m.setActivityCountsAs(nil, for: first, sameName: true)
        XCTAssertTrue(m.workouts.filter { $0.title == "Cardio" }.allSatisfy { $0.activity?.countsAs == nil })
    }

    /// A session renamed on the watch after it came in takes the new name, and
    /// with it the load the name says; one renamed here keeps the person's name.
    @MainActor
    func testARenameOnTheWatchIsTakenUp() async throws {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let m = AppModel(store: try Store(path: ":memory:"), zone: zone, now: { now })
        let a = now.addingTimeInterval(-2 * 86_400), b = now.addingTimeInterval(-86_400)
        func read(_ nameA: String, _ nameB: String) -> ImportSummary {
            m.importWorkouts([
                ImportedWorkout(sourceID: "a", title: nameA, start: a, end: a.addingTimeInterval(1800),
                                activity: ActivitySummary(type: "indoor_cardio", averageHeartRate: 140)),
                ImportedWorkout(sourceID: "b", title: nameB, start: b, end: b.addingTimeInterval(1800),
                                activity: ActivitySummary(type: "indoor_cardio", averageHeartRate: 140)),
            ], source: GarminSource.sourceName, inferSide: false)
        }
        _ = read("Sauna", "Sauna")
        let first = try XCTUnwrap(m.workouts.first { $0.start == a })
        XCTAssertEqual(m.activityLoad(for: first)?.effectiveReps, 0)

        // B is renamed here; then both are renamed on the watch.
        var mine = try XCTUnwrap(m.workouts.first { $0.start == b })
        mine.title = "Steam room"
        m.update(mine)
        let again = read("Stationary Bike", "Stationary Bike")
        XCTAssertEqual(again.activitiesUpdated, 2); XCTAssertEqual(again.activitiesAdded, 0)
        let renamed = try XCTUnwrap(m.workouts.first { $0.start == a })
        XCTAssertEqual(renamed.title, "Stationary Bike")
        XCTAssertEqual(m.activityLoad(for: renamed)?.pattern, "cycling")
        XCTAssertGreaterThan(m.activityLoad(for: renamed)?.effectiveReps ?? 0, 0)
        XCTAssertEqual(m.workouts.first { $0.start == b }?.title, "Steam room")   // the person's name stays
        XCTAssertEqual(m.workouts.count, 2)

        // Reading the same again changes nothing.
        let same = read("Stationary Bike", "Stationary Bike")
        XCTAssertEqual(same.activitiesUpdated, 0); XCTAssertEqual(same.workoutsSkipped, 2)
    }
}
