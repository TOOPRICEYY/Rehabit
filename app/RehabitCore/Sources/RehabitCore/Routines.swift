import Foundation

/// Routines (sessions to start from) and supersets.
extension AppModel {
    // MARK: Routines

    /// Saves a new or changed routine. An empty name becomes "Routine".
    public func save(_ routine: Routine) {
        var routine = routine
        let name = routine.name.trimmingCharacters(in: .whitespacesAndNewlines)
        routine.name = name.isEmpty ? "Routine" : name
        routine.items = routine.items.map(\.clamped)
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
                               mode: block.mode.rawValue, rounds: rounds.filter { !$0.isWarmup }.count,
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
        guard layOut(routine) else { return false }
        changeActive { $0.routineID = routine.id }
        var used = routine
        used.lastUsed = clock
        attempt { try storeRoutine(used) }
        reload()
        return true
    }

    /// Starts a workout as a repeat of a finished one: the same exercises,
    /// rounds, sides and supersets, each set starting from what was done last
    /// time. No routine is saved. Does nothing while a workout is in progress.
    @discardableResult
    public func startWorkout(repeating workout: Workout) -> Bool {
        layOut(routine(from: workout))
    }

    private func layOut(_ routine: Routine) -> Bool {
        guard active == nil else { return false }
        startWorkout(title: routine.name)
        guard active != nil else { return false }
        var groups: [Int: [String]] = [:]
        for item in routine.items.map(\.clamped) {
            let known = library.catalogue.first { $0.name.caseInsensitiveCompare(item.exercise) == .orderedSame }
            let entry = known ?? CatalogueExercise(name: item.exercise, pattern: item.pattern ?? "",
                                                   convention: item.convention, unilateral: item.unilateral, kind: item.kind)
            let mode = SideMode(rawValue: item.mode) ?? startingMode(for: entry)
            // Warm-ups first: the n-th from last time's n-th warm-up, else half of last time's working load.
            for round in 0..<item.warmups {
                for set in addRound(entry, sides: mode.sides) {
                    guard var warm = activeSets.first(where: { $0.id == set.id }) else { continue }
                    let previous = previousSets(exercise: entry.name, side: set.side)
                    let warmups = previous.filter(\.isWarmup)
                    if round < warmups.count {
                        warm.copyPrescription(from: warmups[round])
                    } else if let working = previous.first(where: { !$0.isWarmup }) {
                        warm.copyPrescription(from: working)
                        if let load = warm.loadValue, load > 0 {
                            let step = loadStep(for: warm.exercise, unit: warm.loadUnit)
                            warm.loadValue = min(load, max(step, (load / 2 / step).rounded() * step))
                        }
                    }
                    warm.isWarmup = true; warm.tag = nil
                    update(warm)
                }
            }
            for round in 0..<item.rounds {
                for set in addRound(entry, sides: mode.sides) {
                    // The n-th working set starts from the n-th working set of last time, when there was one.
                    let previous = previousSets(exercise: entry.name, side: set.side).filter { !$0.isWarmup }
                    guard var filled = activeSets.first(where: { $0.id == set.id }) else { continue }
                    filled.isWarmup = false
                    if round < previous.count {
                        filled.copyPrescription(from: previous[round])
                        filled.tag = previous[round].tag
                    }
                    update(filled)
                }
            }
            // The routine's rest applies where the person has not set this exercise's rest themselves.
            if let rest = item.restSeconds, profile.restSeconds[AppModel.restKey(entry.name)] == nil,
               rest != profile.defaultRestSeconds { setRest(rest, for: entry.name) }
            // Grouped under the name the sets carry, whatever spelling the routine held.
            if let group = item.group, !(groups[group] ?? []).contains(entry.name) { groups[group, default: []].append(entry.name) }
        }
        let supersets = groups.keys.sorted().compactMap { groups[$0] }.filter { $0.count > 1 }
        changeActive { workout in
            workout.supersets = supersets.isEmpty ? nil : supersets
            workout.planned = true
        }
        return true
    }

    // MARK: Supersets

    /// The exercises done back to back with this one in the workout in
    /// progress, itself included, in the order they are on the screen. Nil
    /// when fewer than two of the group are still in the workout.
    public func superset(of exercise: String) -> [String]? {
        guard let group = active?.supersets?.first(where: { $0.contains(exercise) }) else { return nil }
        let present = activeBlocks.map(\.exercise).filter { group.contains($0) }
        return present.count > 1 && present.contains(exercise) ? present : nil
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

    /// Supersets name only exercises the workout still has sets of.
    func pruneSupersets() {
        let present = Set(activeSets.map(\.exercise))
        changeActive { workout in
            let groups = (workout.supersets ?? []).map { $0.filter(present.contains) }.filter { $0.count > 1 }
            workout.supersets = groups.isEmpty ? nil : groups
        }
    }

    /// An exercise's turns done in a superset: working rounds done, each with
    /// the drop sets that follow it. A drop set is the tail of its round, not a turn.
    func turnsDone(_ exercise: String) -> Int {
        var turns = 0
        var current: Bool?                   // the turn under way: whether all of it is done so far
        for round in block(exercise).rounds where !round.isWarmup {
            let done = round.members.allSatisfy(\.isDone)
            if round.members.contains(where: { $0.tag == .drop }), let soFar = current {
                current = soFar && done
            } else {
                if current == true { turns += 1 }
                current = done
            }
        }
        return turns + (current == true ? 1 : 0)
    }

    /// In a superset, the set to do after this one: the first set not marked
    /// done of the next exercise in the group that still has one, going round.
    /// Nil outside a superset or when the group has nothing left to do.
    public func supersetNext(after set: WorkoutSet) -> WorkoutSet? {
        guard let group = superset(of: set.exercise), let at = group.firstIndex(of: set.exercise) else { return nil }
        // The others first, in order; this exercise again only when they have nothing left this round.
        let order = Array(group[(at + 1)...] + group[..<at])
        // Counted in rounds, so a left and a right set are one turn.
        let here = turnsDone(set.exercise)
        for name in order where turnsDone(name) < here {
            // It is that exercise's turn: it is behind this one.
            let working = activeSets.filter { $0.exercise == name && !$0.isWarmup }.sorted { $0.position < $1.position }
            if let next = working.first(where: { !$0.isDone }) { return next }
        }
        return nil
    }
}
