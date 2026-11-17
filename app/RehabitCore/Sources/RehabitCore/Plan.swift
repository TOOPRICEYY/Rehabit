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
        // A number no set could reach is a slip of the hand, not a milestone.
        func real(_ value: Double?, most: Double) -> Double? { value.flatMap { $0.isFinite && $0 > 0 && $0 <= most ? $0 : nil } }
        // The name on one line: it is matched against set names and written into the report.
        let name = exercise?.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id; self.title = title; self.exercise = name.flatMap { $0.isEmpty ? nil : $0 }
        self.loadValue = real(loadValue, most: 10_000); self.loadUnit = loadUnit; self.count = real(count, most: 86_400)
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
        self.rule = rule.flatMap { $0.isEmpty ? nil : $0 }
        // Each milestone is told from the others by its id: one repeated gets
        // the same new id every time it is read.
        var seen = Set<String>(), unique: [Milestone] = []
        for var milestone in milestones {
            var copy = 2
            let base = milestone.id
            while seen.contains(milestone.id) { milestone.id = "\(base)#\(copy)"; copy += 1 }
            seen.insert(milestone.id)
            unique.append(milestone)
        }
        self.milestones = unique
        self.setBy = setBy; self.nextVisit = nextVisit
    }

    private enum CodingKeys: String, CodingKey { case rule, milestones, setBy, nextVisit }

    /// Stands in for an entry that could not be read, so the reading moves past it.
    private struct Unreadable: Decodable {}

    /// A part that cannot be read is left out; it must not cost the injury,
    /// and one milestone that cannot be read must not cost the others. A plan
    /// that is not a record at all reads as no plan.
    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self.init(); return }
        var milestones: [Milestone] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .milestones) {
            while !list.isAtEnd {
                if let milestone = try? list.decode(Milestone.self) { milestones.append(milestone) }
                else if (try? list.decode(Unreadable.self)) == nil { break }
            }
        }
        self.init(rule: try? c.decodeIfPresent(PainRule.self, forKey: .rule), milestones: milestones,
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
        guard rounded.isFinite, abs(rounded) < 1e15 else { return String(value) }
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    /// "1 hour", "24 hours", "1.5 hours".
    private static func counted(_ value: Double, _ unit: String) -> String {
        let number = plain(value)
        return "\(number) \(unit)\(number == "1" ? "" : "s")"
    }

    // MARK: Limits

    /// Each finished session of the last `days` days that loaded the injury,
    /// newest first, against the injury's limits. Empty with no limits set.
    public func ruleChecks(for injury: Injury, days: Int = 28) -> [RuleCheck] {
        guard let rule = injury.plan?.rule, !rule.isEmpty else { return [] }
        let today = Day(clock, in: localZone), first = today.adding(-max(1, days) + 1)
        var out: [RuleCheck] = []
        // Newest first by when they began: two sessions of one day are in the order they were done.
        let recent = workouts.filter { $0.startDay >= first && $0.startDay <= today }
            .sorted { ($0.start, $0.id) > ($1.start, $1.id) }
        for workout in recent {
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
                    // A flare-up is a bad moment, not a reading of how the injury is, and is no such evidence.
                    let late = settling.readings.first { check in
                        guard check.moment != .flare else { return false }
                        let at = (check.answeredAt ?? check.dueAt).timeIntervalSince(end) / 3600
                        return at >= limit && (check.pain ?? 0) > baseline + 0.5
                    }
                    if let late {
                        settleOutcome = .over
                        let at = (late.answeredAt ?? late.dueAt).timeIntervalSince(end) / 3600
                        words.append("Still above the level before at \(AppModel.counted(at.rounded(), "hour")); the time set is \(AppModel.counted(limit, "hour")).")
                    } else if let hours, hours <= limit {
                        settleOutcome = .within
                        words.append("Back to the level before by \(AppModel.counted(hours.rounded(), "hour")), inside the \(AppModel.counted(limit, "hour")) set.")
                    } else {
                        words.append("The readings do not show whether it settled within \(AppModel.counted(limit, "hour")).")
                    }
                } else {
                    words.append("No reading before the session to settle back to.")
                }
            }
            out.append(RuleCheck(workoutID: workout.id, day: workout.startDay, title: workout.title,
                                 during: settling.during, duringOutcome: duringOutcome, hoursToSettle: hours,
                                 settleOutcome: settleOutcome, sentence: words.joined(separator: " ")))
        }
        return out
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
        if let hours = rule.settleHours { parts.append("back to the level before within \(AppModel.counted(hours, "hour"))") }
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
        var began = Dictionary(workouts.map { ($0.id, $0.start) }, uniquingKeysWith: { a, _ in a })
        if let active { began[active.id] = active.start }
        // The injured side's own sets, and sets done with both sides together, since the injury may have begun.
        let candidates = sets(named: exercise).filter { set in
            guard !set.isWarmup, set.workoutDay >= injury.earliestOnset, let count = set.count, count > 0 else { return false }
            guard finished.contains(set.workoutID) || set.isDone else { return false }
            return injury.side == .both || set.side == .both || set.side == injury.side
        }.sorted { a, b in
            // In the order they were done: by day, then by when the session began, then by place in it.
            let x = began[a.workoutID] ?? .distantPast, y = began[b.workoutID] ?? .distantPast
            return (a.workoutDay, x, a.position) < (b.workoutDay, y, b.position)
        }
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
            // Ticked by hand before any set met it: reached the day it was ticked.
            if let ticked = milestone.doneOn, ticked < met.workoutDay {
                return MilestoneProgress(milestone: milestone, reachedOn: ticked, set: met,
                                         sentence: "Ticked on \(ticked.readable). First met by a set on \(met.workoutDay.readable): \(said(met)).")
            }
            return MilestoneProgress(milestone: milestone, reachedOn: met.workoutDay, set: met,
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
                                     sentence: "\(exercise) has not been logged \(injury.side == .both ? "" : "on this side ")since the injury began.")
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
        case let (nil, count?): parts.append(hold ? "held \(AppModel.plain(count)) s" : AppModel.counted(count, "rep"))
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
        // Plus zero: a small negative number rounds to minus zero, which reads "-0.0".
        current.effort = effort.flatMap { $0.isFinite ? min(10, max(0, ($0 * 2).rounded() / 2)) + 0 : nil }
        update(current)
    }
}
