import Foundation

/// How an exercise's sets are split between the sides of the body.
public enum SideMode: String, CaseIterable, Codable, Sendable {
    /// Both sides work together: a barbell squat, a push-up.
    case together
    /// Each side logged by itself, a left and a right set per round.
    case perSide
    case leftOnly
    case rightOnly

    public var sides: [Side] {
        switch self {
        case .together: return [.both]
        case .perSide: return [.left, .right]
        case .leftOnly: return [.left]
        case .rightOnly: return [.right]
        }
    }
}

/// One line of the workout screen: a set done with both sides, or a left set
/// and a right set done as a pair. Either half of a pair can be missing.
public struct SetRound: Identifiable, Equatable, Sendable {
    public var both: WorkoutSet?
    public var left: WorkoutSet?
    public var right: WorkoutSet?
    /// Counted from 0 within the exercise, warm-ups included.
    public var index = 0

    public init(both: WorkoutSet? = nil, left: WorkoutSet? = nil, right: WorkoutSet? = nil, index: Int = 0) {
        self.both = both; self.left = left; self.right = right; self.index = index
    }

    public var id: String { [both, left, right].compactMap { $0?.id }.joined(separator: "+") }
    public var members: [WorkoutSet] { [both, left, right].compactMap { $0 } }
    public var isPair: Bool { both == nil }
    public var isWarmup: Bool { members.contains { $0.isWarmup } }
    public func set(on side: Side) -> WorkoutSet? {
        switch side { case .left: return left; case .right: return right; case .both: return both }
    }
    var firstPosition: Int { members.map(\.position).min() ?? 0 }
}

/// Every set of one exercise in a workout, in rounds.
public struct ExerciseBlock: Identifiable, Equatable, Sendable {
    public let exercise: String
    public var sets: [WorkoutSet]
    public var id: String { exercise }

    public init(exercise: String, sets: [WorkoutSet]) { self.exercise = exercise; self.sets = sets }

    /// The mode the sets are in now. A mix of both-sides and one-side sets
    /// counts as per side, so every set keeps a line of its own.
    public var mode: SideMode {
        let sides = Set(sets.map(\.side))
        if sides == [.both] || sides.isEmpty { return .together }
        if sides == [.left] { return .leftOnly }
        if sides == [.right] { return .rightOnly }
        return .perSide
    }

    /// The first set's convention, unit and kind: the card shows them once.
    public var sample: WorkoutSet? { sets.min { $0.position < $1.position } }

    /// Sets with both sides are a round each. A left and a right set that share
    /// a pair id are one round. Sets without one (older records, imports) are
    /// paired in order: the n-th left with the n-th right.
    public var rounds: [SetRound] {
        let ordered = sets.sorted { $0.position < $1.position }
        var rounds = ordered.filter { $0.side == .both }.map { SetRound(both: $0) }
        let lefts = ordered.filter { $0.side == .left }, rights = ordered.filter { $0.side == .right }
        var used = Set<String>()
        var looseLefts: [WorkoutSet] = []
        for left in lefts {
            guard let pair = left.pairID else { looseLefts.append(left); continue }
            let right = rights.first { $0.pairID == pair && !used.contains($0.id) }
            if let right { used.insert(right.id) }
            rounds.append(SetRound(left: left, right: right))
        }
        let rest = rights.filter { !used.contains($0.id) }
        rounds += rest.filter { $0.pairID != nil }.map { SetRound(right: $0) }
        let looseRights = rest.filter { $0.pairID == nil }
        for i in 0..<max(looseLefts.count, looseRights.count) {
            rounds.append(SetRound(left: i < looseLefts.count ? looseLefts[i] : nil,
                                   right: i < looseRights.count ? looseRights[i] : nil))
        }
        rounds.sort { $0.firstPosition < $1.firstPosition }
        for i in rounds.indices { rounds[i].index = i }
        return rounds
    }

    /// Exercises in the order they were first added.
    public static func blocks(_ sets: [WorkoutSet]) -> [ExerciseBlock] {
        var out: [ExerciseBlock] = []
        for set in sets.sorted(by: { $0.position < $1.position }) {
            if let i = out.firstIndex(where: { $0.exercise == set.exercise }) {
                out[i].sets.append(set)
            } else {
                out.append(ExerciseBlock(exercise: set.exercise, sets: [set]))
            }
        }
        return out
    }
}

extension WorkoutSet {
    /// What was lifted and how, the part a left and right set share; not how it felt.
    public var prescription: [Double?] {
        [loadValue, reps, holdSeconds, kind == .hold ? 1 : 0,
         Double(LoadConvention.allCases.firstIndex(of: convention) ?? 0), loadUnit == .kg ? 1 : 0]
    }

    public mutating func copyPrescription(from other: WorkoutSet) {
        loadValue = other.loadValue; reps = other.reps; holdSeconds = other.holdSeconds
        kind = other.kind; convention = other.convention; loadUnit = other.loadUnit
        tempo = other.tempo
    }
}

extension AppModel {
    public var activeBlocks: [ExerciseBlock] { ExerciseBlock.blocks(activeSets) }

    public func block(_ exercise: String) -> ExerciseBlock {
        ExerciseBlock(exercise: exercise, sets: activeSets.filter { $0.exercise == exercise })
    }

    /// The sides of the body with an active injury in a tissue this exercise
    /// really loads. An injury on both sides counts for both.
    public func injuredSides(for exercise: CatalogueExercise) -> Set<Side> {
        // An exercise with no movement mapped could load anything: every injured side counts.
        let pattern = library.pattern(exercise.pattern)
        let loaded = Set((pattern?.links ?? []).filter { $0.share >= 0.25 }.map(\.tissue))
        var sides = Set<Side>()
        for injury in injuries where injury.isActive && (pattern == nil || !loaded.isDisjoint(with: injury.tissues)) {
            sides.formUnion(injury.side.bodySides)
        }
        return sides
    }

    public func injuredSides(of exercise: String) -> Set<Side> {
        guard let set = activeSets.first(where: { $0.exercise == exercise }) else { return [] }
        return injuredSides(for: catalogueEntry(for: set))
    }

    /// Left and right follow each other unless the exercise loads a tissue
    /// injured on one side only: then the two sides are expected to differ.
    public func defaultLinked(_ exercise: String) -> Bool { injuredSides(of: exercise).count != 1 }

    public func isLinked(_ exercise: String) -> Bool { linkOverrides[exercise] ?? defaultLinked(exercise) }

    public func setLinked(_ linked: Bool, for exercise: String) { linkOverrides[exercise] = linked }

    /// The mode a newly added exercise starts in.
    public func startingMode(for exercise: CatalogueExercise) -> SideMode {
        exercise.unilateral ? .perSide : .together
    }

    /// Adds an exercise in a mode, or one more round if it is already in the workout.
    @discardableResult
    public func addExercise(_ exercise: CatalogueExercise, mode: SideMode) -> [WorkoutSet] {
        let existing = block(exercise.name)
        if !existing.sets.isEmpty { return addRound(to: existing) }
        return addRound(exercise, sides: mode.sides)
    }

    /// Adds one round: a set for each side given, each copying the last set
    /// on its own side, or last session's on that side.
    @discardableResult
    public func addRound(_ exercise: CatalogueExercise, sides: [Side]) -> [WorkoutSet] {
        var added = sides.compactMap { addSet(exercise, side: $0) }
        if added.count == 2 {
            // The two halves of a round belong together whatever is removed later.
            let pair = UUID().uuidString
            for i in added.indices { added[i].pairID = pair }
            // A right side with nothing to go on starts from the left, unless the
            // right is the injured side: the healthy side's load is no starting
            // point for it. A linked right side that has drifted follows the left.
            let empty = added[1].loadValue == nil && added[1].reps == nil && added[1].holdSeconds == nil
            let injured = injuredSides(for: exercise).contains(added[1].side)
            if ((empty && !injured) || isLinked(exercise.name)) && added[1].prescription != added[0].prescription {
                added[1].copyPrescription(from: added[0])
            }
            for set in added { update(set) }
        }
        return added
    }

    /// Adds the next round of an exercise already in the workout, in its current mode.
    @discardableResult
    public func addRound(to block: ExerciseBlock) -> [WorkoutSet] {
        guard let last = block.sets.max(by: { $0.position < $1.position }) else { return [] }
        return addRound(catalogueEntry(for: last), sides: block.mode.sides)
    }

    /// Saves a change to one half of a pair. While the sides are linked, a
    /// change to either side's load or reps is copied to the other, unless the
    /// other is already done: what was done is not rewritten, and the two
    /// sides, now different, are unlinked.
    public func update(_ set: WorkoutSet, partner: WorkoutSet?) {
        let before = activeSets.first { $0.id == set.id }
        update(set)
        guard let before, set.prescription != before.prescription, let partner,
              var other = activeSets.first(where: { $0.id == partner.id }), isLinked(set.exercise) else { return }
        guard other.prescription != set.prescription else { return }
        if other.isDone {
            setLinked(false, for: set.exercise)
        } else {
            other.copyPrescription(from: set)
            update(other)
        }
    }

    /// True when going back to "together" would throw away a side that
    /// differs from its partner, so the person should be asked first.
    public func mergeLosesData(_ exercise: String) -> Bool {
        block(exercise).rounds.contains { r in
            guard let l = r.left, let rt = r.right else { return false }
            return l.prescription != rt.prescription || l.pain != rt.pain || l.notes != rt.notes
                || l.painType != rt.painType || l.repsInReserve != rt.repsInReserve
        }
    }

    /// Moves every set of an exercise to another side mode.
    /// - Per side: each set done with both sides becomes the left set and gets
    ///   a right twin with the same numbers (no pain or notes); a lone side
    ///   gets a partner.
    /// - Together or one side: each round keeps the half on `keep` (or the one
    ///   it has) and the other half is removed.
    public func setSideMode(_ mode: SideMode, for exercise: String, keep: Side = .left) {
        let current = block(exercise)
        guard let sample = current.sample, current.mode != mode || mode == .perSide else { return }
        let entry = catalogueEntry(for: sample)
        for round in current.rounds {
            switch mode {
            case .together, .leftOnly, .rightOnly:
                let target: Side = mode == .together ? .both : (mode == .leftOnly ? .left : .right)
                let preferred = mode == .together ? keep : target
                guard var kept = round.both ?? round.set(on: preferred) ?? round.left ?? round.right else { continue }
                // A half with nothing in it gives way to the half that holds the work.
                if !((kept.count ?? 0) > 0), let worked = round.members.first(where: { ($0.count ?? 0) > 0 }) { kept = worked }
                for other in round.members where other.id != kept.id { removeSet(id: other.id) }
                kept.side = target
                // Done if either half was: the work was done, whichever half's numbers are kept.
                kept.completedAt = (kept.count ?? 0) > 0 ? round.members.compactMap(\.completedAt).max() : nil
                if mode == .together { kept.pairID = nil }
                update(kept)
            case .perSide:
                if var both = round.both {
                    both.side = .left
                    update(both)
                    addTwin(of: both, entry: entry, sameSet: true)
                } else if let lone = round.left ?? round.right, round.left == nil || round.right == nil {
                    addTwin(of: lone, entry: entry)
                }
            }
        }
    }

    /// Adds the other side's set for a one-sided set, copying what was lifted.
    /// With `sameSet` the twin is the other half of a set that was done with
    /// both sides (a split), so it is done if that set was; otherwise it is a
    /// set still to do.
    @discardableResult
    func addTwin(of set: WorkoutSet, entry: CatalogueExercise, sameSet: Bool = false, copying: Bool? = nil) -> WorkoutSet? {
        let other: Side = set.side == .left ? .right : .left
        // Unless the person asked for a copy, an injured side is not given the other side's numbers.
        let copying = copying ?? !(injuredSides(for: entry).contains(other) && !injuredSides(for: entry).contains(set.side))
        guard var twin = addSet(entry, side: other) else { return nil }
        var set = activeSets.first { $0.id == set.id } ?? set
        if set.pairID == nil {
            set.pairID = UUID().uuidString
            update(set)
        }
        // A set done with both sides is copied as it was. A new set for a side
        // with an active injury does not take the other side's numbers: it keeps
        // its own from last time, or stays empty, as `addRound` leaves it.
        let injured = !sameSet && copying == false
        if !injured {
            twin.copyPrescription(from: set)
        } else {
            twin.kind = set.kind; twin.convention = set.convention
            if twin.loadValue == nil { twin.loadUnit = set.loadUnit }
        }
        twin.isWarmup = set.isWarmup; twin.tag = set.tag
        twin.range = set.range
        twin.pairID = set.pairID
        twin.completedAt = sameSet ? set.completedAt : nil
        twin.pain = nil; twin.painType = nil; twin.repsInReserve = nil; twin.notes = ""
        update(twin)
        return twin
    }

    /// Makes the other half of a round match this set's numbers, adding it if missing.
    public func copyToOtherSide(_ set: WorkoutSet) {
        guard set.side != .both else { return }
        let round = block(set.exercise).rounds.first { $0.members.contains { $0.id == set.id } }
        let otherSide: Side = set.side == .left ? .right : .left
        if var other = round?.set(on: otherSide) {
            other.copyPrescription(from: set)
            other.isWarmup = set.isWarmup
            update(other)
        } else {
            addTwin(of: set, entry: catalogueEntry(for: set), copying: true)
        }
    }

    /// Fills in a missing half of a round.
    public func fillMissingSide(of round: SetRound) {
        guard round.isPair, let lone = round.left ?? round.right, round.left == nil || round.right == nil else { return }
        addTwin(of: lone, entry: catalogueEntry(for: lone))
    }

    /// Splits one set done with both sides into a left and a right set.
    public func split(_ set: WorkoutSet) {
        guard set.side == .both else { return }
        var left = set
        left.side = .left
        update(left)
        addTwin(of: left, entry: catalogueEntry(for: set), sameSet: true)
    }

    /// Adds a copy of a round at the end of the exercise, with no pain recorded.
    public func duplicate(_ round: SetRound) {
        let pair = round.members.count == 2 ? UUID().uuidString : nil
        for set in round.members {
            guard var copy = addSet(catalogueEntry(for: set), side: set.side) else { continue }
            copy.copyPrescription(from: set)
            copy.isWarmup = set.isWarmup; copy.tag = set.tag; copy.range = set.range
            copy.pairID = pair
            update(copy)
        }
    }

    public func remove(_ round: SetRound) {
        for set in round.members { removeSet(id: set.id) }
    }

    /// Changes something about every set of an exercise at once.
    public func updateAll(of exercise: String, _ change: (inout WorkoutSet) -> Void) {
        for set in block(exercise).sets {
            var changed = set
            change(&changed)
            update(changed)
        }
    }

    /// Moves an exercise one place up (-1) or down (+1) in the workout.
    public func moveExercise(_ exercise: String, by offset: Int) {
        guard let i = activeBlocks.firstIndex(where: { $0.exercise == exercise }),
              activeBlocks.indices.contains(i + offset) else { return }
        moveExercise(exercise, to: i + offset)
    }

    /// Moves an exercise to a place in the workout (0 is first), as a drag does.
    public func moveExercise(_ exercise: String, to index: Int) {
        var blocks = activeBlocks
        guard let from = blocks.firstIndex(where: { $0.exercise == exercise }) else { return }
        let moving = blocks.remove(at: from)
        blocks.insert(moving, at: min(max(0, index), blocks.count))
        var position = 0
        for block in blocks {
            for set in block.sets.sorted(by: { $0.position < $1.position }) {
                if set.position != position {
                    var moved = set
                    moved.position = position
                    update(moved)
                }
                position += 1
            }
        }
    }

    /// Gives an exercise's sets another exercise's name and movement, keeping
    /// the numbers. If the new exercise is already in the workout the two merge.
    public func replaceExercise(_ exercise: String, with replacement: CatalogueExercise) {
        guard exercise != replacement.name else { return }
        if let link = linkOverrides.removeValue(forKey: exercise) { linkOverrides[replacement.name] = link }
        // The replacement takes the exercise's place in its superset.
        changeActive { workout in
            let groups = (workout.supersets ?? []).map { group -> [String] in
                var seen = Set<String>()
                return group.map { $0 == exercise ? replacement.name : $0 }.filter { seen.insert($0).inserted }
            }.filter { $0.count > 1 }
            workout.supersets = groups.isEmpty ? nil : groups
        }
        updateAll(of: exercise) { set in
            set.exercise = replacement.name
            set.pattern = replacement.pattern.isEmpty ? nil : replacement.pattern
            // The numbers are kept where they still mean the same thing. A load on
            // a bar is not a load on a push-up, and reps are not seconds of a plank.
            if set.convention != replacement.convention {
                if replacement.convention == .bodyweight { set.loadValue = nil }
                set.convention = replacement.convention
            }
            if set.kind != replacement.kind {
                set.kind = replacement.kind
                if replacement.kind == .hold { set.reps = nil } else { set.holdSeconds = nil }
            }
        }
    }

    public func removeExercise(_ exercise: String) {
        for set in block(exercise).sets { removeSet(id: set.id) }
        linkOverrides[exercise] = nil
        removeFromSuperset(exercise)
    }

    /// Last session's set on this side at this place in the order, if there was one.
    public func previousSet(exercise: String, side: Side, index: Int) -> WorkoutSet? {
        let previous = previousSets(exercise: exercise, side: side)
        return index < previous.count ? previous[index] : nil
    }

    /// When a set of the workout in progress was last added or changed.
    public var lastActivity: Date? { activeSets.map(\.updatedAt).max() ?? active?.start }

    /// Statements about any set of an exercise, each said once. A jump in
    /// load or a return after a layoff is said once per side, for the set it
    /// is most true of, and names that set: "Left, set 2: ...".
    public func advice(for block: ExerciseBlock) -> [Advice] {
        struct Named { let advice: Advice; let side: Side; let number: Int }
        var perSet: [String: Named] = [:], order: [String] = []
        var seen = Set<String>(), rest: [Advice] = []
        var number = 0
        for round in block.rounds where !round.isWarmup {
            number += 1
            for set in round.members {
                for item in advice(for: set) {
                    if item.kind == .intensityJump || item.kind == .layoff {
                        let key = item.kind.rawValue + "|" + set.side.rawValue
                        if let held = perSet[key], held.advice.amount >= item.amount { continue }
                        if perSet[key] == nil { order.append(key) }
                        perSet[key] = Named(advice: item, side: set.side, number: number)
                    } else if seen.insert(item.detail).inserted {
                        rest.append(item)
                    }
                }
            }
        }
        let named = order.compactMap { perSet[$0] }.map { held -> Advice in
            let which = held.side == .both ? "Set \(held.number)"
                : "\(held.side == .left ? "Left" : "Right"), set \(held.number)"
            let text = held.advice.detail
            return Advice(kind: held.advice.kind, detail: "\(which): \(text.prefix(1).lowercased() + text.dropFirst())",
                          amount: held.advice.amount)
        }
        return named + rest
    }
}
