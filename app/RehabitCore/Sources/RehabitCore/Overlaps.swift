import Foundation

/// Sets a watch recorded with no side, for a movement the session logged by
/// hand at the same time has on one side only. They are probably the other
/// side. A proposal: nothing changes until the person agrees.
public struct OverlapProposal: Identifiable, Equatable, Sendable {
    public let watchWorkoutID: String
    /// The watch's name for the exercise.
    public let exercise: String
    public let setIDs: [String]
    /// The side proposed for them: the one the logged session did not do.
    public let side: Side
    /// What was logged by hand, and on which side.
    public let loggedExercise: String
    public let loggedSide: Side
    public var id: String { watchWorkoutID + "|" + exercise }
}

/// Watch sets of a movement the logged session already has on the same
/// sides: possibly the same work recorded twice.
public struct RepeatedSets: Identifiable, Equatable, Sendable {
    public let watchWorkoutID: String
    public let exercise: String
    public let setIDs: [String]
    public let loggedExercise: String
    public var id: String { watchWorkoutID + "|" + exercise }
}

/// A watch session and a session logged by hand in the same visit to the gym.
public struct SessionOverlap: Identifiable, Equatable, Sendable {
    public let watch: Workout
    public let logged: Workout
    public let proposals: [OverlapProposal]
    public let repeated: [RepeatedSets]
    public var id: String { watch.id + "|" + logged.id }
}

extension AppModel {
    /// Sessions this close together are one visit: a watch started a little
    /// before or stopped a little after the log on the phone.
    static let sameVisit: TimeInterval = 15 * 60

    static func isFromWatch(_ workout: Workout) -> Bool { workout.id.hasPrefix(GarminSource.sourceName + ":") }

    /// Watch sessions that share a gym visit with a logged one and have
    /// something to settle: sets with no side that are probably the other
    /// side, or sets that may be the same work twice. Newest first. A pair
    /// the person has looked at and kept as it is does not come back.
    public var sessionOverlaps: [SessionOverlap] {
        let watches = workouts.filter(AppModel.isFromWatch), logged = workouts.filter { !AppModel.isFromWatch($0) }
        guard !watches.isEmpty, !logged.isEmpty else { return [] }
        var out: [SessionOverlap] = []
        for watch in watches {
            let from = watch.start.addingTimeInterval(-AppModel.sameVisit)
            let to = (watch.end ?? watch.start).addingTimeInterval(AppModel.sameVisit)
            for other in logged where other.start <= to && (other.end ?? other.start) >= from
                && !(watch.overlapsKept ?? []).contains(other.id) {
                let mine = sets(of: other).filter { $0.pattern != nil && !$0.isBlank }
                var proposals: [OverlapProposal] = [], repeated: [RepeatedSets] = []
                for block in ExerciseBlock.blocks(sets(of: watch)) {
                    guard let pattern = block.sample?.pattern else { continue }
                    let same = mine.filter { $0.pattern == pattern }
                    guard let example = same.first else { continue }
                    let sides = Set(same.flatMap(\.side.bodySides))
                    // Only sets whose side nobody chose: a side set by hand is the person's.
                    let open = block.sets.filter { $0.side == .both && $0.sideInferred != false }
                    if sides.count == 1, let side = sides.first, !open.isEmpty {
                        proposals.append(OverlapProposal(
                            watchWorkoutID: watch.id, exercise: block.exercise, setIDs: open.map(\.id),
                            side: side == .left ? .right : .left, loggedExercise: example.exercise, loggedSide: side))
                    } else {
                        let twice = block.sets.filter { Set($0.side.bodySides).isSubset(of: sides) }
                        if !twice.isEmpty {
                            repeated.append(RepeatedSets(watchWorkoutID: watch.id, exercise: block.exercise,
                                                         setIDs: twice.map(\.id), loggedExercise: example.exercise))
                        }
                    }
                }
                if !proposals.isEmpty || !repeated.isEmpty {
                    out.append(SessionOverlap(watch: watch, logged: other, proposals: proposals, repeated: repeated))
                }
            }
        }
        return out.sorted { $0.watch.start > $1.watch.start }
    }

    /// Files the watch's sets under the side proposed. The side is then the
    /// person's choice, and no rule changes it again.
    public func accept(_ proposals: [OverlapProposal]) {
        var changed: [WorkoutSet] = []
        for proposal in proposals {
            for var set in storedSets where proposal.setIDs.contains(set.id) && set.side != proposal.side {
                set.side = proposal.side
                set.sideInferred = false
                set.updatedAt = clock
                changed.append(set)
            }
        }
        guard !changed.isEmpty else { return }
        attempt { try storeSets(changed) }
        reload()
    }

    /// Removes watch sets that were the same work as sets logged by hand.
    public func remove(_ repeated: RepeatedSets) {
        for id in repeated.setIDs { removeSet(id: id) }
        reload()
    }

    /// Keeps a pair of sessions as they are: both count, and it is not asked about again.
    public func keep(_ overlap: SessionOverlap) {
        guard var watch = workouts.first(where: { $0.id == overlap.watch.id }) else { return }
        var kept = watch.overlapsKept ?? []
        guard !kept.contains(overlap.logged.id) else { return }
        kept.append(overlap.logged.id)
        watch.overlapsKept = kept
        update(watch)
    }
}
