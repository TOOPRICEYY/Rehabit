import XCTest
@testable import RehabitCore

final class RestoreTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 1_790_000_000)

    func model(_ store: Store) -> AppModel { AppModel(store: store, zone: zone, now: { [unowned self] in self.clock }) }
    func entry(_ name: String, _ m: AppModel) throws -> CatalogueExercise {
        try XCTUnwrap(m.library.catalogue.first { $0.name == name }, name)
    }
    func log(_ m: AppModel, finish: Bool = true) throws {
        m.startWorkout(title: "Push")
        for _ in 0..<3 {
            var s = try XCTUnwrap(m.addSet(try entry("Bench Press (Barbell)", m)))
            s.loadValue = 100; s.reps = 8; s.pain = 1
            m.update(s)
        }
        clock.addTimeInterval(1800)
        if finish { m.finishWorkout() }
    }

    func testADeletedWorkoutComesBackWithItsSetsHereAndOnTheOtherDevice() throws {
        let m = model(try Store(path: ":memory:")), other = model(try Store(path: ":memory:"))
        try log(m)
        _ = other.merge(try XCTUnwrap(m.exportJSON()))
        XCTAssertEqual(other.workouts.count, 1)
        let workout = m.workouts[0]
        clock.addTimeInterval(60)
        m.deleteWorkout(workout)
        XCTAssertTrue(m.workouts.isEmpty)
        XCTAssertEqual(m.recentlyDeleted.map(\.workout.title), ["Push"]); XCTAssertEqual(m.recentlyDeleted.first?.sets, 3)
        _ = other.merge(try XCTUnwrap(m.exportJSON()))
        XCTAssertTrue(other.workouts.isEmpty)                               // the deletion travelled
        XCTAssertTrue(other.recentlyDeleted.isEmpty)                        // the copy is kept only where it was deleted

        clock.addTimeInterval(3600)
        XCTAssertTrue(m.restoreWorkout(id: workout.id))
        XCTAssertEqual(m.workouts.map(\.id), [workout.id])
        XCTAssertEqual(m.sets(of: m.workouts[0]).map(\.loadValue), [100, 100, 100])
        XCTAssertEqual(m.sets(of: m.workouts[0]).map(\.pain), [1, 1, 1])
        XCTAssertTrue(m.recentlyDeleted.isEmpty)
        XCTAssertFalse(m.restoreWorkout(id: workout.id))                    // nothing left to restore
        _ = other.merge(try XCTUnwrap(m.exportJSON()))
        XCTAssertEqual(other.workouts.map(\.id), [workout.id])              // and so did the return
        XCTAssertEqual(other.sets(of: other.workouts[0]).count, 3)
        XCTAssertNil(m.lastError); XCTAssertNil(other.lastError)
    }

    func testAWorkoutThrownAwayInProgressComesBackFinishedAndOldCopiesAreDropped() throws {
        let m = model(try Store(path: ":memory:"))
        try log(m, finish: false)
        let id = try XCTUnwrap(m.active?.id)
        m.discardWorkout()
        XCTAssertNil(m.active)
        // An empty workout thrown away is not worth keeping.
        m.startWorkout(); m.discardWorkout()
        XCTAssertEqual(m.recentlyDeleted.count, 1)
        XCTAssertTrue(m.restoreWorkout(id: id))
        XCTAssertNil(m.active)
        XCTAssertEqual(m.workouts.first?.end, clock)
        XCTAssertEqual(m.sets(of: m.workouts[0]).count, 3)

        m.deleteWorkout(m.workouts[0])
        clock.addTimeInterval(31 * 86_400)
        m.refreshClock()
        XCTAssertTrue(m.recentlyDeleted.isEmpty)
        XCTAssertFalse(m.restoreWorkout(id: id))
    }
}
