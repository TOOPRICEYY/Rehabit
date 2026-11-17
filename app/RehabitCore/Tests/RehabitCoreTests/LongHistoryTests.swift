import XCTest
@testable import RehabitCore

/// A long history (800 workouts, 12,000 sets) must stay quick where the workout screen reads on every keystroke.
final class LongHistoryTests: XCTestCase {
    let zone = TimeZone(identifier: "America/Detroit")!
    var clock = Date(timeIntervalSince1970: 1_790_000_000)

    @discardableResult
    func ms(_ label: String, _ n: Int = 20, _ body: () -> Void) -> Double {
        body()
        let t = Date()
        for _ in 0..<n { body() }
        let v = Date().timeIntervalSince(t) * 1000 / Double(n)
        print(String(format: "PERF %@: %.2f ms/call", label, v))
        return v
    }

    func testLongHistory() throws {
        let store = try Store(path: ":memory:")
        let cat = Library.standard.catalogue.filter { $0.kind == .reps }
        var workouts: [Workout] = [], sets: [WorkoutSet] = []
        for i in 0..<800 {
            let start = clock.addingTimeInterval(-Double(800 - i) * 86_400 * 1.5)
            var w = Workout(start: start, end: start.addingTimeInterval(3600), zone: zone)
            w.updatedAt = start
            workouts.append(w)
            for p in 0..<15 {
                let e = cat[(i * 5 + p / 3) % cat.count]
                let side: Side = e.unilateral ? (p % 2 == 0 ? .left : .right) : .both
                sets.append(WorkoutSet(workout: w, position: p, exercise: e.name, pattern: e.pattern, side: side,
                                       reps: Double(5 + p % 6), loadValue: Double(50 + (i % 40) * 5), loadUnit: .lb,
                                       convention: e.convention, isWarmup: p == 0, updatedAt: start))
            }
        }
        try store.saveAll(workouts); try store.saveAll(sets)
        let m = AppModel(store: store, zone: zone, now: { [unowned self] in self.clock })
        XCTAssertEqual(m.workouts.count, 800)
        XCTAssertEqual(m.storedSets.count, 12_000)
        m.startWorkout()
        let bench = m.library.catalogue.first { $0.name == "Bench Press (Barbell)" }!
        var s = m.addSet(bench)!
        s.loadValue = 300; s.reps = 5; m.update(s)
        m.setDone(true, s)
        print("PERF sets for bench:", m.storedSets.filter { $0.exercise == bench.name }.count)
        ms("exerciseHistory(bench)") { _ = m.exerciseHistory(bench.name) }
        ms("records(bench,both)") { _ = m.records(for: bench.name, side: .both) }
        ms("recordsBroken(set)") { _ = m.recordsBroken(by: s) }
        ms("loadStep(bench,lb)") { _ = m.loadStep(for: bench.name, unit: .lb) }
        ms("stepped(+1)") { _ = m.stepped(s, load: 1) }
        ms("rest") { _ = m.rest }
        ms("normalise 12k names only") { _ = m.storedSets.map { AppModel.restKey($0.exercise) } }
        ms("filter 12k by exact name only") { _ = m.storedSets.filter { $0.exercise == bench.name } }
        ms("unfinishedSets") { _ = m.unfinishedSets }
        ms("tissueWeeks() warm cache", 5) { _ = m.tissueWeeks() }
        ms("tissueWeeks() after an edit", 5) { s.reps = (s.reps ?? 5) == 5 ? 6 : 5; m.update(s); _ = m.tissueWeeks() }
        ms("previousSets") { _ = m.previousSets(exercise: bench.name, side: .both) }
        ms("addSet+remove", 10) { let x = m.addSet(bench)!; m.removeSet(id: x.id) }
        ms("weekSummary") { _ = m.weekSummary() }
        ms("weeklyStreak") { _ = m.weeklyStreak() }
        let inj = Injury(label: "q", side: .right, onset: Day("2026-01-01")!, tissues: ["quads"])
        ms("symmetry(for injury)", 5) { _ = m.symmetry(for: inj) }
        // One keystroke on the workout screen: a set changes, then fifteen rows read their badges and steps.
        let keystroke = ms("keystroke: edit + 15 rows x (recordsBroken+loadStep+previousSets)", 3) {
            s.reps = (s.reps ?? 5) == 5 ? 6 : 5; m.update(s)
            for _ in 0..<15 {
                _ = m.recordsBroken(by: s); _ = m.loadStep(for: bench.name, unit: .lb)
                _ = m.previousSets(exercise: bench.name, side: .both)
            }
        }
        XCTAssertLessThan(keystroke, 250)       // debug build on a slow machine; it was 834 in release
    }
}
