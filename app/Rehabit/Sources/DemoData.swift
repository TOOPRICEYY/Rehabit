#if DEBUG
import Foundation
import RehabitCore

/// A made-up workout in a throwaway in-memory database, for screenshots and
/// trying the workout screen. Debug builds only, and only when launched with
/// `-demo-workout`; the real database is not opened.
enum DemoData {
    static func modelIfRequested() -> AppModel? {
        guard ProcessInfo.processInfo.arguments.contains("-demo-workout"),
              let store = try? Store(path: ":memory:") else { return nil }
        let model = AppModel(store: store)
        model.profile = Profile(bodyweightKg: 78, unit: .lb)
        model.save(Injury(label: "Left quad strain", side: .left, onset: Day(Date().addingTimeInterval(-20 * 86_400)),
                          tissues: ["quads"]))
        func entry(_ name: String) -> CatalogueExercise { model.library.catalogue.first { $0.name == name }! }
        func fill(_ s: WorkoutSet, _ load: Double?, _ reps: Double?, pain: Double? = nil, warmup: Bool = false) {
            var s = model.activeSets.first { $0.id == s.id } ?? s
            s.loadValue = load; s.reps = reps; s.pain = pain; s.isWarmup = warmup
            model.update(s)
        }
        let squat = entry("Goblet Squat (Dumbbell)"), legExt = entry("Single-Leg Extension (Machine)")
        let row = entry("Single-Arm Row (Dumbbell)")

        // Last session, so each side has its own history.
        model.startWorkout(title: "Lower A")
        for _ in 0..<2 {
            let pair = model.addExercise(legExt, mode: .perSide)
            fill(pair[0], 15, 10, pain: 2); fill(pair[1], 25, 10)
        }
        for _ in 0..<3 { fill(model.addExercise(squat, mode: .together)[0], 35, 10) }
        model.finishWorkout()

        // Today's session, part way through.
        model.startWorkout(title: "Lower B")
        fill(model.addExercise(squat, mode: .together)[0], 20, 10, warmup: true)
        fill(model.addExercise(squat, mode: .together)[0], 40, 8)
        let first = model.addExercise(legExt, mode: .perSide)
        fill(first[0], 15, 10, pain: 1.5); fill(first[1], 25, 10)
        let second = model.addRound(to: model.block(legExt.name))
        fill(second[0], 17.5, 10, pain: 3)
        var right = model.activeSets.first { $0.id == second[1].id }!
        right.range = .full; right.repsInReserve = 2
        model.update(right)
        let rows = model.addExercise(row, mode: .perSide)
        fill(rows[0], 30, 10)
        model.update(model.activeSets.first { $0.id == rows[0].id }!, partner: model.activeSets.first { $0.id == rows[1].id })
        var withNote = model.activeSets.first { $0.id == rows[0].id }!
        withNote.loadValue = 32.5
        model.update(withNote, partner: model.activeSets.first { $0.id == rows[1].id })
        return model
    }
}
#endif
