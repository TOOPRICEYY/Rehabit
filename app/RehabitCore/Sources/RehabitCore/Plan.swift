import Foundation

/// Seconds for each phase of a rep: lowering, the pause at the bottom, lifting,
/// the pause at the top. Written "3-1-1-0", "3/1/1/0" or "3110"; an X means as
/// fast as possible and counts as no time.
public struct Tempo: Equatable, Sendable {
    /// Lowering, bottom, lifting, top. Three numbers leave the top at 0.
    public let phases: [Double]
    /// The tempo as it is stored and shown: "3-1-X-0".
    public let text: String

    public init?(_ written: String) {
        let cleaned = written.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var parts = cleaned.split { !$0.isLetter && !$0.isNumber && $0 != "." }.map(String.init)
        // "3110" and "31x0" are one digit a phase.
        if parts.count == 1, (3...4).contains(parts[0].count), parts[0].allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "x") }) {
            parts = parts[0].map { String($0) }
        }
        guard (3...4).contains(parts.count) else { return nil }
        var seconds: [Double] = [], shown: [String] = []
        for part in parts {
            if part == "x" { seconds.append(0); shown.append("X"); continue }
            guard let value = Double(part), value.isFinite, value >= 0, value <= 60 else { return nil }
            seconds.append(value)
            shown.append(value == value.rounded() ? String(Int(value)) : String(value))
        }
        if seconds.count == 3 { seconds.append(0); shown.append("0") }
        // Every phase at no time is not a tempo.
        guard seconds.contains(where: { $0 > 0 }) else { return nil }
        phases = seconds
        text = shown.joined(separator: "-")
    }

    public var secondsPerRep: Double { phases.reduce(0, +) }
}

extension WorkoutSet {
    /// Seconds the muscle was working in the set: a hold's seconds, or reps
    /// at the set's tempo. Nil for reps with no tempo: the time is not known.
    public var timeUnderTension: Double? {
        if kind == .hold { return holdSeconds.flatMap { $0 > 0 ? $0 : nil } }
        guard let reps, reps > 0, let tempo = tempo.flatMap({ Tempo($0) }) else { return nil }
        return reps * tempo.secondsPerRep
    }
}

/// The limits a person and their therapist agreed for an injury. The app
/// counts sessions against them; it sets none itself.
public struct PainRule: Codable, Equatable, Sendable {
    /// The highest pain a set may reach, 0 to 10. Nil for no limit.
    public var duringMax: Double?
    /// Hours after a session by which pain is to be back within half a point
    /// of the reading before it. Nil for no limit.
    public var settleHours: Double?

    public init(duringMax: Double? = nil, settleHours: Double? = nil) {
        self.duringMax = duringMax.flatMap { $0.isFinite ? min(10, max(0, $0)) : nil }
        self.settleHours = settleHours.flatMap { $0.isFinite && $0 > 0 ? min(60, $0) : nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(duringMax: try? c.decodeIfPresent(Double.self, forKey: .duringMax),
                  settleHours: try? c.decodeIfPresent(Double.self, forKey: .settleHours))
    }

    public var isEmpty: Bool { duringMax == nil && settleHours == nil }
}

/// Something to get back to: "Calf raise, one leg, 20 reps". With an exercise
/// it is reached when a logged set meets it; without one it is ticked by hand.
public struct Milestone: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// The exercise a set must be of. Nil for a milestone ticked by hand only.
    public var exercise: String?
    /// The load as it is typed for a set, at least. Nil for any load.
    public var loadValue: Double?
    public var loadUnit: WeightUnit
    /// Reps, or seconds for a hold, at least. Nil for any.
    public var count: Double?
    /// Pain on the set, at most. A set with no pain recorded does not meet it.
    public var maxPain: Double?
    /// The day it was ticked by hand.
    public var doneOn: Day?

    public init(id: String = UUID().uuidString, title: String, exercise: String? = nil, loadValue: Double? = nil,
                loadUnit: WeightUnit = .lb, count: Double? = nil, maxPain: Double? = nil, doneOn: Day? = nil) {
        func real(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
        let name = exercise?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id; self.title = title; self.exercise = name.flatMap { $0.isEmpty ? nil : $0 }
        self.loadValue = real(loadValue); self.loadUnit = loadUnit; self.count = real(count)
        self.maxPain = maxPain.flatMap { $0.isFinite ? min(10, max(0, $0)) : nil }; self.doneOn = doneOn
    }

    private enum CodingKeys: String, CodingKey { case id, title, exercise, loadValue, loadUnit, count, maxPain, doneOn }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
                  title: (try? c.decode(String.self, forKey: .title)) ?? "",
                  exercise: try? c.decodeIfPresent(String.self, forKey: .exercise),
                  loadValue: try? c.decodeIfPresent(Double.self, forKey: .loadValue),
                  loadUnit: (try? c.decode(WeightUnit.self, forKey: .loadUnit)) ?? .lb,
                  count: try? c.decodeIfPresent(Double.self, forKey: .count),
                  maxPain: try? c.decodeIfPresent(Double.self, forKey: .maxPain),
                  doneOn: try? c.decodeIfPresent(Day.self, forKey: .doneOn))
    }
}

public struct InjuryPlan: Codable, Equatable, Sendable {
    public var rule: PainRule?
    public var milestones: [Milestone]
    /// Who set the plan, as the person wrote it: "Dana, physio".
    public var setBy: String
    public var nextVisit: Day?

    public init(rule: PainRule? = nil, milestones: [Milestone] = [], setBy: String = "", nextVisit: Day? = nil) {
        self.rule = rule.flatMap { $0.isEmpty ? nil : $0 }; self.milestones = milestones
        self.setBy = setBy; self.nextVisit = nextVisit
    }

    private enum CodingKeys: String, CodingKey { case rule, milestones, setBy, nextVisit }

    /// A part that cannot be read is left out; it must not cost the injury.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(rule: try? c.decodeIfPresent(PainRule.self, forKey: .rule),
                  milestones: (try? c.decodeIfPresent([Milestone].self, forKey: .milestones)) ?? [],
                  setBy: (try? c.decodeIfPresent(String.self, forKey: .setBy)) ?? "",
                  nextVisit: try? c.decodeIfPresent(Day.self, forKey: .nextVisit))
    }

    public var isEmpty: Bool { rule == nil && milestones.isEmpty && setBy.isEmpty && nextVisit == nil }
}

/// How a session sat against one limit. Unknown is its own answer: a limit
/// with nothing recorded against it was neither kept nor passed.
public enum RuleOutcome: String, Sendable { case within, over, unknown }

/// One session that loaded an injury, against the injury's limits.
public struct RuleCheck: Identifiable, Equatable, Sendable {
    public let workoutID: String
    public let day: Day
    public let title: String
    /// Highest pain recorded on a set that loaded the injury. Nil if none was.
    public let during: Double?
    /// Nil when the plan sets no limit on pain during sets.
    public let duringOutcome: RuleOutcome?
    /// Hours to the first reading from which pain stayed near the reading before. Nil if not seen.
    public let hoursToSettle: Double?
    /// Nil when the plan sets no time to settle by.
    public let settleOutcome: RuleOutcome?
    /// Both limits in words.
    public let sentence: String
    public var id: String { workoutID }
    public var isOver: Bool { duringOutcome == .over || settleOutcome == .over }
}

/// Sessions counted against the limits over a period.
public struct RuleSummary: Equatable, Sendable {
    public let sessions: Int
    /// Sessions with pain recorded on a set, and those of them over the limit.
    public let duringKnown: Int, duringOver: Int
    /// Sessions whose settling could be told either way, and those of them over the time.
    public let settleKnown: Int, settleOver: Int
}

public struct MilestoneProgress: Identifiable, Equatable, Sendable {
    public let milestone: Milestone
    /// The first day a set met it, or the day it was ticked, whichever came first.
    public let reachedOn: Day?
    /// The set that first met it; when none has, the set that came closest. Nil if the exercise was not done.
    public let set: WorkoutSet?
    public let sentence: String
    public var id: String { milestone.id }
    public var isReached: Bool { reachedOn != nil }
}

extension AppModel {
    private static func plain(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    // MARK: Limits

    /// Each finished session of the last `days` days that loaded the injury,
    /// newest first, against the injury's limits. Empty with no limits set.
    public func ruleChecks(for injury: Injury, days: Int = 28) -> [RuleCheck] {
        guard let rule = injury.plan?.rule, !rule.isEmpty else { return [] }
        let today = Day(clock, in: localZone), first = today.adding(-max(1, days) + 1)
        var out: [RuleCheck] = []
        for workout in workouts where workout.startDay >= first && workout.startDay <= today {
            guard let end = workout.end, let settling = settling(for: workout).first(where: { $0.injury.id == injury.id })
            else { continue }
            var words: [String] = []
            var duringOutcome: RuleOutcome?
            if let limit = rule.duringMax {
                if let during = settling.during {
                    duringOutcome = during > limit + 1e-9 ? .over : .within
                    words.append(duringOutcome == .over
                        ? "Pain during sets reached \(AppModel.plain(during)), above the limit of \(AppModel.plain(limit))."
                        : "Pain during sets reached \(AppModel.plain(during)), within the limit of \(AppModel.plain(limit)).")
                } else {
                    duringOutcome = .unknown
                    words.append("No pain was recorded during sets.")
                }
            }
            var settleOutcome: RuleOutcome?
            let hours = settling.summary?.hoursToSettle
            if let limit = rule.settleHours {
                settleOutcome = .unknown
                if let baseline = settling.baseline {
                    // A reading at or past the limit that is still above the level before shows it had not settled by then.
                    let late = settling.readings.first { check in
                        let at = (check.answeredAt ?? check.dueAt).timeIntervalSince(end) / 3600
                        return at >= limit && (check.pain ?? 0) > baseline + 0.5
                    }
                    if let late {
                        settleOutcome = .over
                        let at = (late.answeredAt ?? late.dueAt).timeIntervalSince(end) / 3600
                        words.append("Still above the level before at \(AppModel.plain(at.rounded())) hours; the time set is \(AppModel.plain(limit)).")
                    } else if let hours, hours <= limit {
                        settleOutcome = .within
                        words.append("Back to the level before by \(AppModel.plain(hours.rounded())) hours, inside the \(AppModel.plain(limit)) set.")
                    } else {
                        words.append("The readings do not show whether it settled within \(AppModel.plain(limit)) hours.")
                    }
                } else {
                    words.append("No reading before the session to settle back to.")
                }
            }
            out.append(RuleCheck(workoutID: workout.id, day: workout.startDay, title: workout.title,
                                 during: settling.during, duringOutcome: duringOutcome, hoursToSettle: hours,
                                 settleOutcome: settleOutcome, sentence: words.joined(separator: " ")))
        }
        return out.sorted { ($0.day, $0.workoutID) > ($1.day, $1.workoutID) }
    }

    public func ruleSummary(for injury: Injury, days: Int = 28) -> RuleSummary? {
        guard let rule = injury.plan?.rule, !rule.isEmpty else { return nil }
        let checks = ruleChecks(for: injury, days: days)
        func known(_ outcome: (RuleCheck) -> RuleOutcome?) -> Int { checks.filter { outcome($0) == .within || outcome($0) == .over }.count }
        return RuleSummary(sessions: checks.count,
                           duringKnown: known(\.duringOutcome), duringOver: checks.filter { $0.duringOutcome == .over }.count,
                           settleKnown: known(\.settleOutcome), settleOver: checks.filter { $0.settleOutcome == .over }.count)
    }

    /// The limits in words, for the injury's screen and its report. Nil with none set.
    public func ruleText(for injury: Injury) -> String? {
        guard let rule = injury.plan?.rule, !rule.isEmpty else { return nil }
        var parts: [String] = []
        if let limit = rule.duringMax { parts.append("pain during sets no higher than \(AppModel.plain(limit))") }
        if let hours = rule.settleHours { parts.append("back to the level before within \(AppModel.plain(hours)) hours") }
        let text = parts.joined(separator: ", and ")
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    // MARK: Milestones

    /// Every milestone of the injury's plan with where it stands, in the plan's order.
    public func milestones(for injury: Injury) -> [MilestoneProgress] {
        (injury.plan?.milestones ?? []).map { progress($0, for: injury) }
    }

    private func progress(_ milestone: Milestone, for injury: Injury) -> MilestoneProgress {
        guard let exercise = milestone.exercise else {
            let sentence = milestone.doneOn.map { "Ticked on \($0.readable)." } ?? "Not ticked yet."
            return MilestoneProgress(milestone: milestone, reachedOn: milestone.doneOn, set: nil, sentence: sentence)
        }
        let finished = Set(workouts.map(\.id))
        // The injured side's own sets, and sets done with both sides together, since the injury may have begun.
        let candidates = sets(named: exercise).filter { set in
            guard !set.isWarmup, set.workoutDay >= injury.earliestOnset, let count = set.count, count > 0 else { return false }
            guard finished.contains(set.workoutID) || set.isDone else { return false }
            return injury.side == .both || set.side == .both || set.side == injury.side
        }.sorted { ($0.workoutDay, $0.position) < ($1.workoutDay, $1.position) }
        func loadMet(_ set: WorkoutSet) -> Bool {
            guard let need = milestone.loadValue else { return true }
            guard let load = set.loadValue else { return false }
            return load * set.loadUnit.kilograms >= need * milestone.loadUnit.kilograms - 0.01
        }
        func countMet(_ set: WorkoutSet) -> Bool { milestone.count.map { (set.count ?? 0) >= $0 - 1e-9 } ?? true }
        func painMet(_ set: WorkoutSet) -> Bool { milestone.maxPain.map { limit in set.pain.map { $0 <= limit + 1e-9 } ?? false } ?? true }
        func said(_ set: WorkoutSet) -> String {
            var text = describe(set)
            if milestone.maxPain != nil { text += set.pain.map { ", pain \(AppModel.plain($0))" } ?? ", no pain recorded" }
            return text
        }
        if let met = candidates.first(where: { loadMet($0) && countMet($0) && painMet($0) }) {
            let day = min(met.workoutDay, milestone.doneOn ?? met.workoutDay)
            return MilestoneProgress(milestone: milestone, reachedOn: day, set: met,
                                     sentence: "Reached on \(met.workoutDay.readable): \(said(met)).")
        }
        // Closest: the most parts met, then the heavier, then the longer.
        func score(_ set: WorkoutSet) -> (Int, Double, Double) {
            ((loadMet(set) ? 1 : 0) + (countMet(set) ? 1 : 0) + (painMet(set) ? 1 : 0),
             (set.loadValue ?? 0) * set.loadUnit.kilograms, set.count ?? 0)
        }
        let closest = candidates.max { score($0) < score($1) }
        if let ticked = milestone.doneOn {
            return MilestoneProgress(milestone: milestone, reachedOn: ticked, set: closest, sentence: "Ticked on \(ticked.readable).")
        }
        guard let closest else {
            return MilestoneProgress(milestone: milestone, reachedOn: nil, set: nil,
                                     sentence: "\(exercise) has not been logged on this side since the injury began.")
        }
        return MilestoneProgress(milestone: milestone, reachedOn: nil, set: closest,
                                 sentence: "Closest so far: \(said(closest)) on \(closest.workoutDay.readable).")
    }

    /// What a milestone asks for, in words: "Calf Raise: 40 lb x 20, pain 2 or less".
    public func milestoneText(_ milestone: Milestone) -> String {
        guard let exercise = milestone.exercise else { return milestone.title }
        var parts: [String] = []
        let hold = sets(named: exercise).last?.kind == .hold
            || library.catalogue.first { $0.name.caseInsensitiveCompare(exercise) == .orderedSame }?.kind == .hold
        switch (milestone.loadValue, milestone.count) {
        case let (load?, count?):
            parts.append(hold ? "\(AppModel.plain(load)) \(milestone.loadUnit.rawValue) held \(AppModel.plain(count)) s"
                              : "\(AppModel.plain(load)) \(milestone.loadUnit.rawValue) x \(AppModel.plain(count))")
        case let (load?, nil): parts.append("\(AppModel.plain(load)) \(milestone.loadUnit.rawValue)")
        case let (nil, count?): parts.append(hold ? "held \(AppModel.plain(count)) s" : "\(AppModel.plain(count)) reps")
        default: break
        }
        if let pain = milestone.maxPain { parts.append("pain \(AppModel.plain(pain)) or less") }
        return parts.isEmpty ? exercise : "\(exercise): \(parts.joined(separator: ", "))"
    }

    /// Ticks a milestone by hand, or takes the tick away.
    public func setMilestone(_ id: String, done: Bool, for injury: Injury) {
        guard var current = injuries.first(where: { $0.id == injury.id }), var plan = current.plan,
              let at = plan.milestones.firstIndex(where: { $0.id == id }) else { return }
        let day: Day? = done ? Day(clock, in: localZone) : nil
        guard plan.milestones[at].doneOn != day, !(done && plan.milestones[at].doneOn != nil) else { return }
        plan.milestones[at].doneOn = day
        current.plan = plan
        save(current)
    }

    // MARK: Notes kept with an exercise

    public func exerciseNote(for exercise: String) -> String { profile.exerciseNotes[AppModel.restKey(exercise)] ?? "" }

    public func setExerciseNote(_ note: String, for exercise: String) {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var notes = profile.exerciseNotes
        notes[AppModel.restKey(exercise)] = text.isEmpty ? nil : String(text.prefix(2000))
        profile.exerciseNotes = notes
    }

    // MARK: Effort

    /// Saves how hard a finished session felt, 0 to 10 in half points. Nil clears it.
    public func setEffort(_ effort: Double?, for workout: Workout) {
        guard var current = workouts.first(where: { $0.id == workout.id }) else { return }
        current.effort = effort.flatMap { $0.isFinite ? min(10, max(0, ($0 * 2).rounded() / 2)) : nil }
        update(current)
    }
}
