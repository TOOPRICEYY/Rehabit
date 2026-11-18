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
/// What kind of set it is, as one choice.
public enum SetLabel: String, CaseIterable, Sendable { case working, warmup, drop, failure }

extension WorkoutSet {
    public var label: SetLabel { isWarmup ? .warmup : tag == .drop ? .drop : tag == .failure ? .failure : .working }
}

/// A hold being timed: which set, since when, and how long it is meant to be.
public struct HoldRun: Equatable, Sendable {
    public let setID: String
    /// The exercise the set was of when the hold began: a set since changed to another is not this hold's.
    public let exercise: String
    public let startedAt: Date
    /// The seconds planned for the set when the hold began. Nil when none were.
    public let target: Double?
    public func elapsed(at time: Date) -> TimeInterval { max(0, time.timeIntervalSince(startedAt)) }
    /// Seconds left to the target, never below zero. Nil without a target.
    public func remaining(at time: Date) -> TimeInterval? { target.map { max(0, $0 - elapsed(at: time)) } }
    public func reachedTarget(at time: Date) -> Bool { target.map { elapsed(at: time) >= $0 } ?? false }
}

extension AppModel {
    // MARK: Holds

    /// Starts timing a hold of the workout in progress. The seconds already
    /// on the set are the target to count down to. A hold already being timed
    /// is dropped unsaved. False if the set is not in the workout.
    @discardableResult
    public func startHold(_ set: WorkoutSet) -> Bool {
        guard let current = activeSets.first(where: { $0.id == set.id }) else { return false }
        let planned = current.kind == .hold ? current.holdSeconds.flatMap { $0 > 0 && $0.isFinite ? $0 : nil } : nil
        holdRun = HoldRun(setID: current.id, exercise: current.exercise, startedAt: clock,
                          target: current.isDone ? nil : planned)
        return true
    }

    /// Ends the hold being timed and saves the seconds actually held, to the
    /// half second. Kept from the clock, so time spent with the phone locked counts.
    /// `asPlanned` saves the target when the hold ran that long and no more than
    /// a tenth over it, two seconds at most: stopping a 45 second hold a moment
    /// late is still a 45 second hold, and 9 seconds for a planned 5 is 9.
    @discardableResult
    public func stopHold(asPlanned: Bool = true) -> Bool {
        guard let run = holdRun else { return false }
        holdRun = nil
        // The set must still be there and still be of the exercise that was being held.
        guard let set = activeSets.first(where: { $0.id == run.setID }), set.exercise == run.exercise else { return false }
        var held = min(run.elapsed(at: clock), 3600)
        if asPlanned, let target = run.target, held >= target, held <= target + min(2, target * 0.1) { held = target }
        finishHold(set, seconds: held)
        return activeSets.first { $0.id == set.id }?.isDone ?? false
    }

    /// Drops the hold being timed without saving anything.
    public func cancelHold() { holdRun = nil }

    /// The set to do next in the workout in progress: in a superset the next
    /// exercise's turn, otherwise the first set not done after the one last
    /// marked done, otherwise the first not done at all. Nil when the person
    /// is not using done marks or nothing is left.
    public var nextUp: WorkoutSet? {
        guard usesDoneMarks else { return nil }
        let ordered = activeSets.sorted { $0.position < $1.position }
        // A mark since taken off again points nowhere.
        if let last = lastMarkedDone.flatMap({ id in ordered.first { $0.id == id && $0.isDone } }) {
            let other: Side? = last.side == .left ? .right : last.side == .right ? .left : nil
            let round = block(last.exercise).rounds.first { $0.members.contains { $0.id == last.id } }
            if let partner = other.flatMap({ round?.set(on: $0) }), !partner.isDone {
                // The other half of the round first, unless the person does one side at a time:
                // then the same side's next set, and the other side when this one is through.
                if waitsForOtherSide(last) { return partner }
                if let same = ordered.first(where: { $0.exercise == last.exercise && $0.side == last.side
                    && $0.position > last.position && !$0.isDone }) { return same }
                return partner
            }
            if let next = supersetNext(after: last) { return next }
            if let next = ordered.first(where: { $0.position > last.position && !$0.isDone }) { return next }
        }
        return ordered.first { !$0.isDone }
    }

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
        if done {
            guard let count = current.count, count.isFinite, count > 0 else { return false }
        }
        var changed = current
        changed.completedAt = done ? clock : nil
        // Done with reps and no weight, where a weight is what the number means: the
        // weight of the set before it in this workout, the same side first.
        if done, changed.loadValue == nil, changed.convention == .perHand || changed.convention == .total {
            let earlier = sets(ofWorkout: current.workoutID)
                .filter { $0.exercise == current.exercise && $0.position < current.position && $0.loadValue != nil }
                .sorted { $0.position > $1.position }
            if let above = earlier.first(where: { $0.side == current.side }) ?? earlier.first {
                changed.loadValue = above.loadValue; changed.loadUnit = above.loadUnit
            }
        }
        update(changed)
        // A countdown ended or changed by hand belonged to the mark just changed.
        if restAdjust?.setID == current.id { restAdjust = nil }
        if restSkippedFor == current.id { restSkippedFor = nil }
        lastMarkedDone = done ? current.id : (lastMarkedDone == current.id ? nil : lastMarkedDone)
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
        let held = seconds.isFinite ? max(0, (seconds * 2).rounded() / 2) : 0
        current.holdSeconds = held
        // A hold stopped before it began was not done.
        current.completedAt = held > 0 ? clock : nil
        update(current)
        // A rest ended or changed by hand belonged to the mark before this one.
        if restAdjust?.setID == current.id { restAdjust = nil }
        if restSkippedFor == current.id { restSkippedFor = nil }
        if held > 0 { lastMarkedDone = current.id } else if lastMarkedDone == current.id { lastMarkedDone = nil }
    }

    /// Sets of the workout in progress not marked done, when some are. With
    /// nothing marked done the person is not using the marks, and none count as unfinished.
    /// A warm-up the person typed and did not tick is not one of them: only a
    /// warm-up laid out from a routine and left untouched is.
    public var unfinishedSets: [WorkoutSet] {
        activeSets.filter { !$0.isDone && ($0.planned == true || (usesDoneMarks && !$0.isWarmup)) }
    }

    /// True when sets of the workout in progress count only once marked done:
    /// a set has been marked, or the workout was laid out ahead from a
    /// routine or a repeat, whose rows are a plan until they are done.
    public var usesDoneMarks: Bool { activeSets.contains { $0.isDone } || active?.planned == true }

    func sets(ofWorkout id: String) -> [WorkoutSet] { storedSets.filter { $0.workoutID == id } }

    // MARK: Rest

    /// An hour: longer than any rest, and short enough that the sums cannot overflow.
    static let longestRest = 3600

    static func restKey(_ exercise: String) -> String {
        exercise.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Seconds of rest after a set of this exercise.
    public func restSeconds(for exercise: String) -> Int {
        min(AppModel.longestRest, max(0, profile.restSeconds[AppModel.restKey(exercise)] ?? profile.defaultRestSeconds))
    }

    /// Sets this exercise's own rest. Nil goes back to the default.
    public func setRest(_ seconds: Int?, for exercise: String) {
        var all = profile.restSeconds
        all[AppModel.restKey(exercise)] = seconds.map { min(AppModel.longestRest, max(0, $0)) }
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
        // The set just marked, even if the clock was set back since an earlier one; else the latest by time.
        let marked = lastMarkedDone.flatMap { id in activeSets.first { $0.id == id && $0.isDone } }
        guard let last = marked ?? activeSets.filter({ $0.isDone }).max(by: { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }),
              let started = last.completedAt, !last.isWarmup else { return nil }
        let extra = restAdjust.flatMap { $0.setID == last.id ? $0.seconds : nil } ?? 0
        let base = restSeconds(for: last.exercise)
        let seconds = base + extra
        guard base > 0, seconds > 0, restSkippedFor != last.id else { return nil }
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
        // Working rounds only: a warm-up skipped on one side says nothing about how the sets are done.
        let oneSideAtATime = rounds.prefix(round.index).contains { earlier in
            guard !earlier.isWarmup, let own = earlier.set(on: set.side), let theirs = earlier.set(on: other) else { return false }
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

    public func skipRest() {
        restSkippedAt = clock
        restSkippedFor = rest?.setID
    }

    /// Makes the rest running now longer or shorter, this once. The
    /// exercise's own rest (`setRest`) is not changed.
    public func adjustRest(by seconds: Int) {
        guard let timer = rest else { return }
        let before = restAdjust.flatMap { $0.setID == timer.setID ? $0.seconds : nil } ?? 0
        let limit = AppModel.longestRest
        restAdjust = RestAdjust(setID: timer.setID, seconds: min(limit, max(-limit, before + min(limit, max(-limit, seconds)))))
    }

    // MARK: Steps

    /// The usual jump in load for this exercise, in a unit: the step seen most
    /// often between the loads already used (the smaller on a tie), so one
    /// mistyped load does not change it; else 5 lb or 2.5 kg.
    public func loadStep(for exercise: String, unit: WeightUnit) -> Double {
        let usual = unit == .lb ? 5.0 : 2.5
        // Working sets that were done: a warm-up at the bare bar, or a number
        // still being typed, says nothing about the plates this exercise goes up by.
        let activeID = active?.id
        let loads = Set(sets(named: exercise).filter { $0.loadUnit == unit && !$0.isWarmup && ($0.workoutID != activeID || $0.isDone) }
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
        // A gap seen once is two weights that happen to be that far apart, not a step.
        // Unless it is small enough to be a stack's or a plate pair's step, it is not taken for one.
        guard most >= 2 else { return smallest <= usual * 2 ? smallest : usual }
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
            let barbell = set.convention == .total && set.exercise.lowercased().contains("barbell")
            if barbell, (set.loadValue ?? 0) <= 0, load > 0 {
                // Nothing lighter than the empty bar can be on it.
                out.loadValue = Plates.bar(set.loadUnit) + Double(load - 1) * step
            } else {
                out.loadValue = max(0, (set.loadValue ?? 0) + Double(load) * step)
            }
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

    /// Makes a set a working set, a warm-up, a drop set or a set to failure, directly.
    public func setLabel(_ label: SetLabel, for set: WorkoutSet) {
        guard var changed = activeSets.first(where: { $0.id == set.id }) ?? sets(ofWorkout: set.workoutID).first(where: { $0.id == set.id })
        else { return }
        changed.isWarmup = label == .warmup
        changed.tag = label == .drop ? .drop : label == .failure ? .failure : nil
        update(changed)
    }

    /// The same for both halves of a round.
    public func setLabel(_ label: SetLabel, for round: SetRound) {
        for member in round.members { setLabel(label, for: member) }
    }

    /// The unit an exercise's page is shown in: the unit of its latest set
    /// with a load, else the person's own.
    public func displayUnit(for exercise: String) -> WeightUnit {
        sets(named: exercise).filter { $0.loadValue != nil }
            .max { ($0.workoutDay, $0.updatedAt) < ($1.workoutDay, $1.updatedAt) }?.loadUnit ?? profile.unit
    }

    /// What an exercise's loads mean where that is not the number typed, for
    /// its page. Nil for an exercise loaded by the bar or the hand.
    public func loadNote(for exercise: String) -> String? {
        let convention = sets(named: exercise).max { ($0.workoutDay, $0.updatedAt) < ($1.workoutDay, $1.updatedAt) }?.convention
            ?? library.catalogue.first { $0.name.caseInsensitiveCompare(exercise) == .orderedSame }?.convention
        guard let convention, convention != .perHand, convention != .total else { return nil }
        guard profile.bodyweightKg != nil || !bodyweightHistory.isEmpty else {
            return "Loads for this exercise include your body weight. Add it in Settings to see them."
        }
        switch convention {
        case .bodyweightMinus: return "Loads are your share of body weight less the assistance, so less assistance reads as heavier."
        case .bodyweightPlus: return "Loads are your share of body weight plus the weight added."
        default: return "Loads are your share of body weight."
        }
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
