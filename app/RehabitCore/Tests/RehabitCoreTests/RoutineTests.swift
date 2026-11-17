import XCTest
@testable import RehabitCore

final class RoutineTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 1_790_000_000)

    func model(_ store: Store? = nil) throws -> AppModel {
        AppModel(store: try store ?? Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
    }
    func entry(_ name: String, _ m: AppModel) throws -> CatalogueExercise {
        try XCTUnwrap(m.library.catalogue.first { $0.name == name }, name)
    }
    func fill(_ m: AppModel, _ set: WorkoutSet, load: Double, reps: Double) {
        var set = set
        set.loadValue = load; set.reps = reps
        m.update(set)
    }

    func testARoutineMadeFromAWorkoutLaysTheNextOneOutFromLastTimesNumbers() throws {
        let store = try Store(path: ":memory:")
        let m = try model(store)
        m.startWorkout(title: "Legs")
        let bench = try entry("Bench Press (Barbell)", m), ext = try entry("Single-Leg Extension (Machine)", m)
        // Bench: a warm-up and two working sets, 135 x 8 then 140 x 6.
        fill(m, try XCTUnwrap(m.addSet(bench)), load: 135, reps: 8)
        fill(m, m.addRound(to: m.block(bench.name))[0], load: 140, reps: 6)
        _ = m.addWarmupRound(to: m.block(bench.name))
        // Extensions per side, two rounds: left 60, right 20 then 25.
        let first = m.addExercise(ext, mode: .perSide)
        m.setLinked(false, for: ext.name)
        fill(m, first[0], load: 60, reps: 10); fill(m, first[1], load: 20, reps: 12)
        let second = m.addRound(to: m.block(ext.name))
        fill(m, second[0], load: 60, reps: 10); fill(m, second[1], load: 25, reps: 10)
        m.setRest(60, for: ext.name)
        m.setSuperset([ext.name, bench.name])
        XCTAssertEqual(m.superset(of: bench.name), [bench.name, ext.name])       // in the workout's order
        m.finishWorkout()

        let routine = m.routine(from: m.workouts[0])
        XCTAssertEqual(routine.name, "Legs")
        XCTAssertEqual(routine.items.map(\.exercise), [bench.name, ext.name])
        XCTAssertEqual(routine.items.map(\.rounds), [2, 2]); XCTAssertEqual(routine.items.map(\.warmups), [1, 0])
        XCTAssertEqual(routine.items.map(\.mode), ["together", "perSide"])
        XCTAssertEqual(routine.items.map(\.restSeconds), [nil, 60])
        XCTAssertEqual(routine.items.map(\.group), [0, 0])
        m.save(routine)
        XCTAssertEqual(m.routines.map(\.name), ["Legs"])

        // A relaunch later, the routine starts a workout laid out the same way.
        clock.addTimeInterval(2 * 86_400)
        let again = try model(store)
        XCTAssertTrue(again.startWorkout(from: try XCTUnwrap(again.routines.first)))
        XCTAssertEqual(again.active?.title, "Legs"); XCTAssertEqual(again.active?.routineID, routine.id)
        let blocks = again.activeBlocks
        XCTAssertEqual(blocks.map(\.exercise), [bench.name, ext.name])
        let benchRounds = blocks[0].rounds
        XCTAssertEqual(benchRounds.map(\.isWarmup), [true, false, false])
        XCTAssertEqual(benchRounds.map { $0.both?.loadValue }, [70, 135, 140])            // each set from the same set last time
        XCTAssertEqual(benchRounds.map { $0.both?.reps }, [8, 8, 6])
        let extRounds = blocks[1].rounds
        XCTAssertEqual(extRounds.map { $0.left?.loadValue }, [60, 60]); XCTAssertEqual(extRounds.map { $0.right?.loadValue }, [20, 25])
        XCTAssertEqual(extRounds.map { $0.right?.reps }, [12, 10])
        XCTAssertTrue(again.activeSets.allSatisfy { !$0.isDone && $0.pain == nil })
        XCTAssertEqual(again.superset(of: ext.name), [bench.name, ext.name])
        XCTAssertEqual(again.routines.first?.lastUsed, clock)
        XCTAssertFalse(again.startWorkout(from: routine))                           // one workout at a time
        XCTAssertNil(again.lastError)
    }

    func testInASupersetTheRestComesAfterTheLastExercise() throws {
        let m = try model()
        m.startWorkout()
        let bench = try entry("Bench Press (Barbell)", m), row = try entry("Seated Row (Cable)", m)
        var sets: [String: [WorkoutSet]] = [:]
        for exercise in [bench, row] {
            for _ in 0..<2 {
                let set = try XCTUnwrap(m.addSet(exercise))
                fill(m, set, load: 100, reps: 8)
                sets[exercise.name, default: []].append(set)
            }
        }
        m.setSuperset([bench.name, row.name])
        m.setDone(true, sets[bench.name]![0])
        XCTAssertNil(m.rest)                                                        // straight on to the row
        XCTAssertEqual(m.supersetNext(after: m.activeSets[0])?.id, sets[row.name]![0].id)
        clock.addTimeInterval(40)
        m.setDone(true, sets[row.name]![0])
        XCTAssertEqual(m.rest?.exercise, row.name)                                  // the round is done: rest
        XCTAssertNil(m.supersetNext(after: sets[row.name]![0]))
        // Out of the superset, a set rests by itself again.
        m.removeFromSuperset(row.name)
        XCTAssertNil(m.superset(of: bench.name))
        clock.addTimeInterval(200)
        m.setDone(true, sets[bench.name]![1])
        XCTAssertEqual(m.rest?.exercise, bench.name)
    }

    func testRoutinesSyncAndArriveThroughTheInbox() throws {
        let m = try model()
        let routine = Routine(name: "  ", items: [RoutineItem(exercise: "Wall Sit", pattern: "squat_bodyweight",
                                                             convention: .bodyweight, kind: .hold, rounds: 0)])
        m.save(routine)
        XCTAssertEqual(m.routines.first?.name, "Routine"); XCTAssertEqual(m.routines.first?.items.first?.rounds, 1)
        let other = try model()
        XCTAssertEqual(other.merge(try XCTUnwrap(m.exportJSON())), 1)
        XCTAssertEqual(other.routines.map(\.id), [routine.id])
        other.deleteRoutine(id: routine.id)
        XCTAssertEqual(m.merge(try XCTUnwrap(other.exportJSON())), 1)               // the deletion comes back
        XCTAssertTrue(m.routines.isEmpty)

        // A routine prepared elsewhere is listed, then taken in when the person says so.
        let file = Data("""
        {"schemaVersion": 1, "routines": [
          {"id": "plan-a", "name": "Plan A", "notes": "Week 1", "updatedAt": "2026-11-17T17:00:00.000Z", "items": [
            {"id": "i1", "exercise": "Single-Leg Extension (Machine)", "pattern": "leg_extension", "convention": "total",
             "unilateral": true, "kind": "reps", "mode": "perSide", "rounds": 3, "warmups": 0, "notes": ""},
            {"id": "i2", "exercise": "Wall Sit", "pattern": "squat_bodyweight", "convention": "bodyweight",
             "unilateral": false, "kind": "hold", "mode": "together", "rounds": 4, "warmups": 0, "restSeconds": 90, "notes": ""}]}]}
        """.utf8)
        XCTAssertEqual(try m.incoming(file).routines.map(\.name), ["Plan A"])
        XCTAssertEqual(m.takeIn(file), 1)
        XCTAssertTrue(m.startWorkout(from: try XCTUnwrap(m.routines.first)))
        XCTAssertEqual(m.activeBlocks.map { $0.rounds.count }, [3, 4])
        XCTAssertEqual(m.activeBlocks[1].sets.first?.kind, .hold)
        XCTAssertEqual(m.restSeconds(for: "Wall Sit"), 90)
        XCTAssertNil(m.lastError)
    }
}
