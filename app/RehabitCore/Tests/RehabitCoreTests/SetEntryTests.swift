import XCTest
@testable import RehabitCore

/// The workout screen's behaviour, off the screen: rounds, side modes, linked sides.
final class SetEntryTests: XCTestCase {
    var clock = Date(timeIntervalSince1970: 1_763_300_000)
    let zone = TimeZone(identifier: "America/Detroit")!

    func makeModel() throws -> AppModel {
        let model = AppModel(store: try Store(path: ":memory:"), zone: zone, now: { [unowned self] in self.clock })
        model.startWorkout()
        return model
    }

    func entry(_ model: AppModel, _ name: String) throws -> CatalogueExercise {
        try XCTUnwrap(model.library.catalogue.first { $0.name == name })
    }

    func set(_ model: AppModel, _ s: WorkoutSet, load: Double? = nil, reps: Double? = nil, partner: WorkoutSet? = nil) {
        var s = model.activeSets.first { $0.id == s.id } ?? s
        if let load { s.loadValue = load }
        if let reps { s.reps = reps }
        let p = partner.flatMap { p in model.activeSets.first { $0.id == p.id } }
        model.update(s, partner: p)
    }

    func testOneSidedExercisesStartPerSideAndAddRoundsInPairs() throws {
        let model = try makeModel()
        let row = try entry(model, "Single-Arm Row (Dumbbell)")
        XCTAssertEqual(model.startingMode(for: row), .perSide)
        let first = model.addExercise(row, mode: .perSide)
        XCTAssertEqual(first.map(\.side), [.left, .right])
        set(model, first[0], load: 30, reps: 10, partner: first[1])
        model.addRound(to: model.block(row.name))
        let block = model.block(row.name)
        XCTAssertEqual(block.mode, .perSide)
        XCTAssertEqual(block.rounds.count, 2)
        XCTAssertEqual(block.rounds[1].left?.loadValue, 30)
        XCTAssertEqual(block.rounds[1].right?.loadValue, 30)      // linked: followed the left
        // Adding it from the picker again adds a round, not a second card.
        model.addExercise(row, mode: .together)
        XCTAssertEqual(model.activeBlocks.count, 1)
        XCTAssertEqual(model.block(row.name).rounds.count, 3)
    }

    func testLinkedSidesFollowEachOtherUntilOneIsDone() throws {
        let model = try makeModel()
        let curl = try entry(model, "Biceps Curl (Dumbbell)")
        model.addExercise(curl, mode: .together)
        model.setSideMode(.perSide, for: curl.name)
        var r = model.block(curl.name).rounds[0]
        XCTAssertTrue(model.isLinked(curl.name))
        set(model, r.left!, load: 20, reps: 12, partner: r.right)
        r = model.block(curl.name).rounds[0]
        XCTAssertEqual(r.right?.loadValue, 20)
        XCTAssertEqual(r.right?.reps, 12)
        set(model, r.right!, load: 15, partner: r.left)              // the right changed: the left follows too
        XCTAssertTrue(model.isLinked(curl.name))
        r = model.block(curl.name).rounds[0]
        XCTAssertEqual(r.left?.loadValue, 15)
        // Once the left is done it is not rewritten: the right goes its own way and the link ends.
        XCTAssertTrue(model.setDone(true, r.left!))
        set(model, r.right!, load: 25, partner: r.left)
        r = model.block(curl.name).rounds[0]
        XCTAssertEqual(r.left?.loadValue, 15)
        XCTAssertEqual(r.right?.loadValue, 25)
        XCTAssertFalse(model.isLinked(curl.name))
        set(model, r.left!, load: 30, partner: r.right)              // unlinked: no longer follows
        XCTAssertEqual(model.block(curl.name).rounds[0].right?.loadValue, 25)
    }

    func testAOneSidedInjuryUnlinksAndMarksItsSide() throws {
        let model = try makeModel()
        model.save(Injury(label: "Left quad strain", side: .left, onset: Day("2025-11-01")!, tissues: ["quads"]))
        let ext = try entry(model, "Single-Leg Extension (Machine)")
        model.addExercise(ext, mode: .perSide)
        XCTAssertEqual(model.injuredSides(of: ext.name), [.left])
        XCTAssertFalse(model.isLinked(ext.name))
        let r = model.block(ext.name).rounds[0]
        set(model, r.left!, load: 15, reps: 10, partner: r.right)
        XCTAssertNil(model.block(ext.name).rounds[0].right?.loadValue)   // injured side does not drag the other
        XCTAssertTrue(model.injuredSides(of: "Biceps Curl (Dumbbell)").isEmpty)
    }

    func testEachSideAddsATwinWithNumbersButNoPain() throws {
        let model = try makeModel()
        let press = try entry(model, "Shoulder Press (Dumbbell)")
        var s = try XCTUnwrap(model.addExercise(press, mode: .together).first)
        s.loadValue = 35; s.reps = 8; s.pain = 3; s.notes = "pinch at top"
        model.update(s)
        model.setSideMode(.perSide, for: press.name)
        let r = model.block(press.name).rounds[0]
        XCTAssertEqual(r.left?.pain, 3)
        XCTAssertEqual(r.left?.notes, "pinch at top")
        XCTAssertEqual(r.right?.loadValue, 35)
        XCTAssertEqual(r.right?.reps, 8)
        XCTAssertNil(r.right?.pain)
        XCTAssertEqual(r.right?.notes, "")
        XCTAssertEqual(model.activeSets.count, 2)
    }

    func testBackToTogetherAsksOnlyWhenSidesDiffer() throws {
        let model = try makeModel()
        let lunge = try entry(model, "Lunge (Dumbbell)")
        let pair = model.addExercise(lunge, mode: .perSide)
        set(model, pair[0], load: 20, reps: 10, partner: pair[1])
        XCTAssertFalse(model.mergeLosesData(lunge.name))
        model.setLinked(false, for: lunge.name)
        set(model, model.block(lunge.name).rounds[0].right!, load: 25)
        XCTAssertTrue(model.mergeLosesData(lunge.name))
        model.setSideMode(.together, for: lunge.name, keep: .right)
        let block = model.block(lunge.name)
        XCTAssertEqual(block.mode, .together)
        XCTAssertEqual(block.sets.count, 1)
        XCTAssertEqual(block.sets[0].loadValue, 25)
    }

    func testOneSideOnlyKeepsThatSide() throws {
        let model = try makeModel()
        let step = try entry(model, "Step-Up (Dumbbell)")
        model.addExercise(step, mode: .perSide)
        model.addRound(to: model.block(step.name))
        model.setSideMode(.rightOnly, for: step.name)
        let block = model.block(step.name)
        XCTAssertEqual(block.mode, .rightOnly)
        XCTAssertEqual(block.sets.count, 2)
        XCTAssertEqual(model.addRound(to: block).map(\.side), [.right])
    }

    func testCopyFillSplitDuplicateRemove() throws {
        let model = try makeModel()
        let row = try entry(model, "Single-Arm Row (Dumbbell)")
        let pair = model.addExercise(row, mode: .perSide)
        model.setLinked(false, for: row.name)
        set(model, pair[0], load: 40, reps: 8)
        model.copyToOtherSide(model.block(row.name).rounds[0].left!)
        XCTAssertEqual(model.block(row.name).rounds[0].right?.loadValue, 40)

        // A round missing its right half gets one filled in.
        model.removeSet(id: pair[1].id)
        XCTAssertNil(model.block(row.name).rounds[0].right)
        model.fillMissingSide(of: model.block(row.name).rounds[0])
        XCTAssertEqual(model.block(row.name).rounds[0].right?.loadValue, 40)

        model.duplicate(model.block(row.name).rounds[0])
        XCTAssertEqual(model.block(row.name).rounds.count, 2)
        XCTAssertNil(model.block(row.name).rounds[1].left?.pain)
        model.remove(model.block(row.name).rounds[1])
        XCTAssertEqual(model.block(row.name).rounds.count, 1)

        let squat = try entry(model, "Goblet Squat (Dumbbell)")
        let s = try XCTUnwrap(model.addExercise(squat, mode: .together).first)
        model.split(s)
        XCTAssertEqual(model.block(squat.name).mode, .perSide)
    }

    func testMoveReplaceAndRemoveExercises() throws {
        let model = try makeModel()
        let a = try entry(model, "Squat (Barbell)"), b = try entry(model, "Leg Curl (Machine)")
        let c = try entry(model, "Plank")
        model.addExercise(a, mode: .together)
        model.addExercise(b, mode: .together)
        model.addRound(to: model.block(a.name))                     // a's second set comes after b's
        model.addExercise(c, mode: .together)
        model.moveExercise(c.name, by: -1)
        XCTAssertEqual(model.activeBlocks.map(\.exercise), [a.name, c.name, b.name])
        model.moveExercise(a.name, by: -1)                           // already first: nothing happens
        XCTAssertEqual(model.activeBlocks.map(\.exercise), [a.name, c.name, b.name])
        XCTAssertEqual(model.block(a.name).sets.count, 2)

        var s = model.block(b.name).sets[0]
        s.loadValue = 50; model.update(s)
        let nordic = try entry(model, "Single-Leg Curl (Machine)")
        model.replaceExercise(b.name, with: nordic)
        XCTAssertTrue(model.block(b.name).sets.isEmpty)
        XCTAssertEqual(model.block(nordic.name).sets.first?.loadValue, 50)
        XCTAssertEqual(model.block(nordic.name).sets.first?.pattern, nordic.pattern)

        model.removeExercise(c.name)
        XCTAssertEqual(model.activeBlocks.map(\.exercise), [a.name, nordic.name])
    }

    func testPreviousSetByPlaceAndSideAndCardAdvice() throws {
        let model = try makeModel()
        model.save(Injury(label: "Left quad strain", side: .left, onset: Day("2025-11-01")!, tissues: ["quads"]))
        let ext = try entry(model, "Single-Leg Extension (Machine)")
        let pair = model.addExercise(ext, mode: .perSide)
        set(model, pair[0], load: 15, reps: 10)
        set(model, pair[1], load: 25, reps: 10)
        model.addRound(to: model.block(ext.name))
        set(model, model.block(ext.name).rounds[1].left!, load: 17.5)
        model.finishWorkout()
        clock.addTimeInterval(2 * 86_400)
        model.startWorkout()
        XCTAssertEqual(model.previousSet(exercise: ext.name, side: .left, index: 1)?.loadValue, 17.5)
        XCTAssertEqual(model.previousSet(exercise: ext.name, side: .right, index: 0)?.loadValue, 25)
        XCTAssertNil(model.previousSet(exercise: ext.name, side: .right, index: 5))
        // Each side starts from its own last session, injured or not.
        let again = model.addExercise(ext, mode: .perSide)
        XCTAssertEqual(again.map(\.loadValue), [15, 25])
        let advice = model.advice(for: model.block(ext.name))
        XCTAssertEqual(advice.count, Set(advice.map(\.detail)).count)     // each said once
        XCTAssertTrue(advice.contains { $0.kind == .injuredTissue })
    }
}
