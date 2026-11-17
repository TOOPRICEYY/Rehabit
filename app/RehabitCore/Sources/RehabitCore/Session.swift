import Foundation

/// The rest counted down after a set was marked done.
public struct RestTimer: Equatable, Sendable {
    public let exercise: String
    public let setID: String
    public let startedAt: Date
    public let seconds: Int
    public var endsAt: Date { startedAt.addingTimeInterval(Double(seconds)) }
    /// Never more than the rest's own length, even if the clock was set back meanwhile.
    public func remaining(at time: Date) -> TimeInterval { min(Double(seconds), max(0, endsAt.timeIntervalSince(time))) }
}

/// A change to one rest countdown, not to the exercise's rest.
public struct RestAdjust: Equatable, Sendable {
    public let setID: String
    public let seconds: Int
}

/// Doing a workout: marking sets done, resting, stepping the load, warming up.
extension AppModel {
    // MARK: Done

    /// Marks a set done now, or back to planned. A set marked done keeps the
    /// time, so the rest between sets can be read afterwards. A set with no
    /// reps (or, for a hold, no seconds) is not marked done: false comes back
    /// and the screen asks for the number.
    @discardableResult
    public func setDone(_ done: Bool, _ set: WorkoutSet) -> Bool {
        guard let current = activeSets.first(where: { $0.id == set.id }) ?? sets(ofWorkout: set.workoutID).first(where: { $0.id == set.id })
        else { return false }
        guard current.isDone != done else { return true }
        if done, (current.count ?? 0) <= 0 { return false }
        var changed = current
        changed.completedAt = done ? clock : nil
        update(changed)
        return true
    }

    /// Marks every half of a round done (or planned again). False if a half
    /// had no reps and was left as it was.
    @discardableResult
    public func setDone(_ done: Bool, _ round: SetRound) -> Bool {
        var all = true
        for set in round.members where !setDone(done, set) { all = false }
        return all
    }

    /// Finishes a timed hold: the seconds actually held, and done.
    public func finishHold(_ set: WorkoutSet, seconds: Double) {
        guard var current = activeSets.first(where: { $0.id == set.id }) else { return }
        current.kind = .hold
        current.holdSeconds = max(0, (seconds * 2).rounded() / 2)
        current.completedAt = clock
        update(current)
    }

    /// Sets of the workout in progress not marked done, when some are. With
    /// nothing marked done the person is not using the marks, and none count as unfinished.
    public var unfinishedSets: [WorkoutSet] {
        activeSets.contains { $0.isDone } ? activeSets.filter { !$0.isDone } : []
    }

    func sets(ofWorkout id: String) -> [WorkoutSet] { storedSets.filter { $0.workoutID == id } }

    // MARK: Rest

    static func restKey(_ exercise: String) -> String {
        exercise.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Seconds of rest after a set of this exercise.
    public func restSeconds(for exercise: String) -> Int {
        max(0, profile.restSeconds[AppModel.restKey(exercise)] ?? profile.defaultRestSeconds)
    }

    /// Sets this exercise's own rest. Nil goes back to the default.
    public func setRest(_ seconds: Int?, for exercise: String) {
        var all = profile.restSeconds
        all[AppModel.restKey(exercise)] = seconds.map { max(0, $0) }
        profile.restSeconds = all
    }

    /// The rest running now: from the set most recently marked done in the
    /// workout in progress, unless it was a warm-up, its rest is off, it has
    /// run out more than an hour ago, or the countdown was dismissed.
    ///
    /// A left and a right set are one round: the rest starts when both are
    /// done. Someone doing every set of one side first is recognised from the
    /// round before (their side done there, the other not), and rests after each set.
    public var rest: RestTimer? {
        guard let last = activeSets.filter({ $0.isDone }).max(by: { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }),
              let started = last.completedAt, !last.isWarmup else { return nil }
        let extra = restAdjust.flatMap { $0.setID == last.id ? $0.seconds : nil } ?? 0
        let base = restSeconds(for: last.exercise)
        let seconds = base + extra
        guard base > 0, seconds > 0, restSkippedAt.map({ $0 < started }) ?? true else { return nil }
        // In a superset the rest comes after the last exercise of the group that still has this round to do.
        if let next = supersetNext(after: last), next.exercise != last.exercise { return nil }
        if waitsForOtherSide(last) || dropFollows(last) { return nil }
        let timer = RestTimer(exercise: last.exercise, setID: last.id, startedAt: started, seconds: seconds)
        return clock.timeIntervalSince(timer.endsAt) < 3600 ? timer : nil
    }

    /// True when this set is one half of a round whose other half is still to
    /// do, and nothing shows the person does one side at a time.
    func waitsForOtherSide(_ set: WorkoutSet) -> Bool {
        guard set.side != .both else { return false }
        let other: Side = set.side == .left ? .right : .left
        let rounds = block(set.exercise).rounds
        guard let round = rounds.first(where: { $0.members.contains { $0.id == set.id } }),
              let partner = round.set(on: other), !partner.isDone else { return false }
        let oneSideAtATime = rounds.prefix(round.index).contains { earlier in
            guard let own = earlier.set(on: set.side), let theirs = earlier.set(on: other) else { return false }
            return own.isDone && !theirs.isDone
        }
        return !oneSideAtATime
    }

    /// True when the next set of this exercise on this side is a drop set
    /// still to do: it follows at once, and the rest comes after it.
    func dropFollows(_ set: WorkoutSet) -> Bool {
        let later = activeSets.filter { $0.exercise == set.exercise && $0.side == set.side && $0.position > set.position }
        guard let next = later.min(by: { $0.position < $1.position }) else { return false }
        return next.tag == .drop && !next.isDone
    }

    public func skipRest() { restSkippedAt = clock }

    /// Makes the rest running now longer or shorter, this once. The
    /// exercise's own rest (`setRest`) is not changed.
    public func adjustRest(by seconds: Int) {
        guard let timer = rest else { return }
        let before = restAdjust.flatMap { $0.setID == timer.setID ? $0.seconds : nil } ?? 0
        restAdjust = RestAdjust(setID: timer.setID, seconds: before + seconds)
    }

    // MARK: Steps

    /// The usual jump in load for this exercise, in a unit: the step seen most
    /// often between the loads already used (the smaller on a tie), so one
    /// mistyped load does not change it; else 5 lb or 2.5 kg.
    public func loadStep(for exercise: String, unit: WeightUnit) -> Double {
        let usual = unit == .lb ? 5.0 : 2.5
        let loads = Set(sets(named: exercise).filter { $0.loadUnit == unit }
            .compactMap(\.loadValue).filter { $0 > 0 && $0.isFinite }).sorted()
        var gaps: [Double] = []
        for (higher, lower) in zip(loads.dropFirst(), loads) {
            let gap: Double = ((higher - lower) * 100).rounded() / 100
            if gap >= 0.25 { gaps.append(gap) }
        }
        guard let smallest = gaps.min() else { return usual }
        // With two loads the gap may just be two far-apart weights: it only ever
        // makes the step smaller. Three or more show the plates' or the stack's real step.
        guard loads.count >= 3 else { return min(smallest, usual) }
        var counts: [Double: Int] = [:]
        for gap in gaps { counts[gap, default: 0] += 1 }
        let most = counts.values.max() ?? 0
        let common = counts.filter { $0.value == most }.keys.min() ?? smallest
        return min(common, unit == .lb ? 25 : 10)
    }

    /// The set with its load moved by whole steps and its reps (or, for a
    /// hold, its time in fives of seconds) by whole counts. Never below zero.
    public func stepped(_ set: WorkoutSet, load: Int = 0, count: Int = 0) -> WorkoutSet {
        var out = set
        // Stepping down from a load not entered leaves it not entered: unknown is not zero.
        if load != 0, set.loadValue != nil || load > 0 {
            let step = loadStep(for: set.exercise, unit: set.loadUnit)
            out.loadValue = max(0, (set.loadValue ?? 0) + Double(load) * step)
        }
        if count != 0 {
            if set.kind == .hold {
                out.holdSeconds = max(0, (set.holdSeconds ?? 0) + Double(count) * 5)
            } else {
                out.reps = max(0, (set.reps ?? 0) + Double(count))
            }
        }
        return out
    }

    // MARK: Warm-up

    /// Adds a warm-up round ahead of the exercise's working sets: each side at
    /// about half of that side's own working load, to the nearest step and
    /// never above the working load.
    @discardableResult
    public func addWarmupRound(to block: ExerciseBlock) -> [WorkoutSet] {
        var added: [WorkoutSet] = []
        let working = block.sets.filter { !$0.isWarmup }.sorted { $0.position < $1.position }
        let injured = block.sample.map { injuredSides(for: catalogueEntry(for: $0)) } ?? []
        for set in addRound(to: block) {
            var warm = set
            // The other side's working set stands in only for a side that is not injured.
            let own = working.first { $0.side == set.side }
            if let source = own ?? (injured.contains(set.side) ? nil : working.first) {
                warm.copyPrescription(from: source)
                if let load = warm.loadValue, load > 0 {
                    let step = loadStep(for: warm.exercise, unit: warm.loadUnit)
                    warm.loadValue = min(load, max(step, (load / 2 / step).rounded() * step))
                }
            }
            warm.isWarmup = true
            update(warm)
            added.append(warm)
        }
        // Warm-ups go first: the block keeps its places in the workout, in a new order.
        let now = self.block(block.exercise).sets.sorted { $0.position < $1.position }
        let ordered = now.filter(\.isWarmup) + now.filter { !$0.isWarmup }
        for (set, position) in zip(ordered, now.map(\.position)) where set.position != position {
            var moved = set
            moved.position = position
            update(moved)
        }
        return added.compactMap { a in activeSets.first { $0.id == a.id } }
    }

    // MARK: Unit

    /// Shows an exercise's loads in another unit. Converting keeps the weight
    /// (100 lb becomes 45.359 kg); not converting keeps the
    /// numbers, for loads that were typed under the wrong unit. With
    /// `rounding`, a converted load goes to the nearest weight that exists in
    /// the new unit (half a kilogram, one pound): 20 lb reads 9 kg, not 9.07.
    public func setUnit(_ unit: WeightUnit, for exercise: String, converting: Bool = true, rounding: Bool = false) {
        updateAll(of: exercise) { set in
            guard set.loadUnit != unit else { return }
            if converting, let value = set.loadValue {
                // The exact weight, so converting back gives the number first typed and
                // the same weight never reads as a new record. Screens round what they show.
                let exact = value * set.loadUnit.kilograms / unit.kilograms
                let near = (exact * 1000).rounded() / 1000
                set.loadValue = abs(near - exact) < 1e-7 ? near : exact
                if rounding { set.loadValue = AppModel.rounded(exact, in: unit) }
            }
            set.loadUnit = unit
        }
    }

    /// A weight to the nearest half kilogram or whole pound.
    public static func rounded(_ value: Double, in unit: WeightUnit) -> Double {
        let grain = unit == .kg ? 0.5 : 1.0
        return (value / grain).rounded() * grain
    }

    // MARK: Set kinds

    /// The next kind of set, as a tap on the set's number cycles them:
    /// working set, warm-up, drop set, to failure, and round again.
    public func cycleKind(_ set: WorkoutSet) {
        guard var changed = activeSets.first(where: { $0.id == set.id }) ?? sets(ofWorkout: set.workoutID).first(where: { $0.id == set.id })
        else { return }
        if changed.isWarmup { changed.isWarmup = false; changed.tag = .drop }
        else if changed.tag == .drop { changed.tag = .failure }
        else if changed.tag != nil { changed.tag = nil }
        else { changed.isWarmup = true }
        update(changed)
    }

    /// The same for both halves of a round, which are one kind of set.
    public func cycleKind(_ round: SetRound) {
        guard let first = round.members.first else { return }
        cycleKind(first)
        guard let now = activeSets.first(where: { $0.id == first.id }) ?? sets(ofWorkout: first.workoutID).first(where: { $0.id == first.id })
        else { return }
        for other in round.members.dropFirst() {
            var changed = other
            changed.isWarmup = now.isWarmup; changed.tag = now.tag
            update(changed)
        }
    }

    // MARK: Prefill

    /// What a first set of an exercise starts from: last session on this side,
    /// or, where there is none, last session on another side, unless this side
    /// has an active injury the exercise loads. A healthy side's numbers are
    /// not a starting point for an injured one.
    public func prefillSets(for exercise: CatalogueExercise, side: Side) -> [WorkoutSet] {
        let own = previousSets(exercise: exercise.name, side: side)
        guard own.isEmpty else { return own }
        let injured = injuredSides(for: exercise)
        guard injured.isDisjoint(with: side.bodySides) else { return [] }
        let others: [Side] = side == .both ? [.left, .right] : [side == .left ? .right : .left, .both]
        for other in others {
            let sets = previousSets(exercise: exercise.name, side: other)
            if !sets.isEmpty { return sets }
        }
        return []
    }
}
