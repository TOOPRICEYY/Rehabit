import Foundation

/// Routines (sessions to start from) and supersets.
extension AppModel {
    // MARK: Routines

    /// Saves a new or changed routine. An empty name becomes "Routine".
    public func save(_ routine: Routine) {
        var routine = routine
        let name = routine.name.trimmingCharacters(in: .whitespacesAndNewlines)
        routine.name = name.isEmpty ? "Routine" : name
        routine.updatedAt = clock
        attempt { try storeRoutine(routine) }
        reload()
    }

    public func deleteRoutine(id: String) {
        attempt { try removeRoutine(id: id) }
        reload()
    }

    /// A routine made from a workout: its exercises in order, each with the
    /// rounds, warm-ups, sides and supersets it had. Loads are not copied;
    /// they come from the last session when the routine is started.
    public func routine(from workout: Workout, name: String? = nil) -> Routine {
        let groups = workout.supersets ?? []
        let items = ExerciseBlock.blocks(sets(of: workout)).compactMap { block -> RoutineItem? in
            guard let sample = block.sample else { return nil }
            let entry = catalogueEntry(for: sample)
            let rounds = block.rounds
            let own = profile.restSeconds[AppModel.restKey(block.exercise)]
            return RoutineItem(exercise: block.exercise, pattern: sample.pattern, convention: sample.convention,
                               unilateral: entry.unilateral || block.mode != .together, kind: sample.kind,
                               mode: block.mode.rawValue, rounds: max(1, rounds.filter { !$0.isWarmup }.count),
                               warmups: rounds.filter(\.isWarmup).count, restSeconds: own,
                               group: groups.firstIndex { $0.contains(block.exercise) })
        }
        return Routine(name: name ?? workout.title, items: items, updatedAt: clock)
    }

    /// Starts a workout from a routine: every exercise with its rounds laid
    /// out, each set starting from the same set of the last session on that
    /// side. Does nothing while another workout is in progress.
    @discardableResult
    public func startWorkout(from routine: Routine) -> Bool {
        guard active == nil else { return false }
        startWorkout(title: routine.name)
        guard active != nil else { return false }
        for item in routine.items {
            let known = library.catalogue.first { $0.name.caseInsensitiveCompare(item.exercise) == .orderedSame }
            let entry = known ?? CatalogueExercise(name: item.exercise, pattern: item.pattern ?? "",
                                                   convention: item.convention, unilateral: item.unilateral, kind: item.kind)
            let mode = SideMode(rawValue: item.mode) ?? startingMode(for: entry)
            for round in 0..<max(1, item.rounds) {
                for set in addRound(entry, sides: mode.sides) {
                    // The n-th working set starts from the n-th working set of last time, when there was one.
                    let previous = previousSets(exercise: entry.name, side: set.side).filter { !$0.isWarmup }
                    guard round < previous.count, var filled = activeSets.first(where: { $0.id == set.id }) else { continue }
                    filled.copyPrescription(from: previous[round])
                    update(filled)
                }
            }
            for _ in 0..<item.warmups { addWarmupRound(to: block(entry.name)) }
            if let rest = item.restSeconds, rest != restSeconds(for: entry.name) { setRest(rest, for: entry.name) }
        }
        var groups: [Int: [String]] = [:]
        for item in routine.items { if let group = item.group { groups[group, default: []].append(item.exercise) } }
        let supersets = groups.keys.sorted().compactMap { groups[$0] }.filter { $0.count > 1 }
        changeActive { workout in
            workout.routineID = routine.id
            workout.supersets = supersets.isEmpty ? nil : supersets
        }
        var used = routine
        used.lastUsed = clock
        attempt { try storeRoutine(used) }
        reload()
        return true
    }

    // MARK: Supersets

    /// The exercises done back to back with this one in the workout in progress, itself included, in order.
    public func superset(of exercise: String) -> [String]? {
        active?.supersets?.first { $0.contains(exercise) }
    }

    /// Makes these exercises of the workout in progress one superset. Each is
    /// taken out of any other group first. Fewer than two leaves none.
    public func setSuperset(_ exercises: [String]) {
        let present = activeBlocks.map(\.exercise).filter { exercises.contains($0) }
        changeActive { workout in
            var groups = (workout.supersets ?? []).map { $0.filter { !present.contains($0) } }.filter { $0.count > 1 }
            if present.count > 1 { groups.append(present) }
            workout.supersets = groups.isEmpty ? nil : groups
        }
    }

    /// Takes one exercise out of its superset.
    public func removeFromSuperset(_ exercise: String) {
        changeActive { workout in
            let groups = (workout.supersets ?? []).map { $0.filter { $0 != exercise } }.filter { $0.count > 1 }
            workout.supersets = groups.isEmpty ? nil : groups
        }
    }

    /// In a superset, the set to do after this one: the first set not marked
    /// done of the next exercise in the group that still has one, going round.
    /// Nil outside a superset or when the group has nothing left to do.
    public func supersetNext(after set: WorkoutSet) -> WorkoutSet? {
        guard let group = superset(of: set.exercise), let at = group.firstIndex(of: set.exercise) else { return nil }
        // The others first, in order; this exercise again only when they have nothing left this round.
        let order = Array(group[(at + 1)...] + group[..<at])
        // Counted in rounds, so a left and a right set are one turn.
        func turnsDone(_ name: String) -> Int {
            block(name).rounds.filter { !$0.isWarmup && $0.members.allSatisfy(\.isDone) }.count
        }
        let here = turnsDone(set.exercise)
        for name in order where turnsDone(name) < here {
            // It is that exercise's turn: it is behind this one.
            let working = activeSets.filter { $0.exercise == name && !$0.isWarmup }.sorted { $0.position < $1.position }
            if let next = working.first(where: { !$0.isDone }) { return next }
        }
        return nil
    }
}
