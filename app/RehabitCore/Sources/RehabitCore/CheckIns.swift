import Foundation

/// One question on the check-in screen, with what is needed to answer it in a tap.
public struct CheckInItem: Identifiable, Equatable, Sendable {
    public let check: PainCheck
    public let injury: Injury
    /// The injury's most recent reading to a question (not a flare-up logged
    /// in between), shown beside this one. Nil if it has never been answered.
    public let last: PainCheck?
    /// What "unchanged" would record: the last reading, if it is recent
    /// enough to stand for today. Nil when a number has to be given.
    public let unchangedValue: Double?
    /// For a follow-up to a session: the highest pain recorded on a set of
    /// that session that loaded this injury. Pain under load is not a reading
    /// of how the injury is, so it is shown beside the question, never copied.
    public let sessionPain: Double?
    public var id: String { check.id }
}

/// One reminder for all the questions that fall due together. Six injuries
/// asked about at 8:00 are one notification, not six.
public struct ReminderRound: Identifiable, Equatable, Sendable {
    /// The same for the same time and questions, so scheduling twice replaces it.
    public let id: String
    public let fireAt: Date
    public let checkIDs: [String]
    public let injuryLabels: [String]
    public let moments: [PainCheckMoment]

    public var title: String {
        injuryLabels.count == 1 ? "How is \(injuryLabels[0])?" : "Pain check-in for \(injuryLabels.count) injuries"
    }
    public var body: String {
        let when = moments.count == 1 ? moments[0].label : "Several follow-ups"
        return injuryLabels.count == 1 ? "\(when). A few seconds."
                                       : "\(when): \(injuryLabels.joined(separator: ", ")). One screen, a few seconds."
    }
}

/// How one injury's pain went after one session.
public struct SessionSettling: Equatable, Sendable {
    public let injury: Injury
    /// The reading going in: the last question answered in the three days before the session
    /// (a flare-up logged in between is not one). Nil if there was none.
    public let baseline: Double?
    /// Readings from the end of the session to 60 hours after, in order, whatever prompted them.
    public let readings: [PainCheck]
    /// The highest pain recorded on a set of the session that loaded the injury. Nil if none was.
    public let during: Double?
    /// Questions asked in that time, answered or not. Flare-ups are readings but were not asked.
    public let asked: Int
    /// Nil without a baseline to settle back to.
    public let summary: SettlingSummary?
}

extension AppModel {
    /// The id of a day's morning question for an injury. Fixed, so the same
    /// question answered on two devices is one record.
    static func dailyCheckID(injuryID: String, day: Day) -> String { "daily:\(injuryID):\(day)" }

    /// "Unchanged" copies a reading no older than this.
    static let unchangedWindow: TimeInterval = 3 * 86_400

    /// The morning questions for a run of days: one for each active injury,
    /// unless that morning's question is already stored (answered or skipped).
    /// These are not stored until answered, so a year of ignored mornings
    /// leaves nothing behind. Whether one is asked is decided in `standing`.
    func dailyChecks(from first: Day, days: Int) -> [PainCheck] {
        guard profile.dailyCheckIn else { return [] }
        var out: [PainCheck] = []
        let stored = Dictionary(checks.map { ($0.id, $0.dueAt) }, uniquingKeysWith: { a, _ in a })
        for offset in 0..<max(0, days) {
            let day = first.adding(offset)
            guard let due = schedule.morning(of: day) else { continue }
            for injury in injuries where injury.isActive && injury.earliestOnset <= day {
                var id = AppModel.dailyCheckID(injuryID: injury.id, day: day)
                if let held = stored[id] {
                    // The same date answered in another time zone was another morning.
                    if abs(held.timeIntervalSince(due)) < PainSchedule.sameReading { continue }
                    id += ":\(Stamp.millis(due))"
                    if stored[id] != nil { continue }
                }
                out.append(PainCheck(id: id, injuryID: injury.id, workoutID: nil, moment: .baseline, dueAt: due,
                                     zone: localZone, updatedAt: due))
            }
        }
        return out
    }

    /// One injury's questions with those that would double a reading taken
    /// out. Two questions closer than `sameReading` are one reading: an
    /// answered or skipped one stands for both, else the earlier is asked.
    /// "Right after the session" is always asked. Flare-ups are not questions
    /// and are left out.
    static func standing(_ questions: [PainCheck]) -> [PainCheck] {
        let ordered = questions.filter { $0.moment != .flare }.sorted {
            ($0.dueAt, $0.isOpen ? 1 : 0, $0.workoutID == nil ? 1 : 0, $0.id) < ($1.dueAt, $1.isOpen ? 1 : 0, $1.workoutID == nil ? 1 : 0, $1.id)
        }
        func near(_ a: PainCheck, _ b: PainCheck) -> Bool {
            abs(a.dueAt.timeIntervalSince(b.dueAt)) < PainSchedule.sameReading
        }
        let taken = ordered.filter { !$0.isOpen }
        var kept: [PainCheck] = []
        for check in ordered {
            if check.isOpen, check.moment != .afterSession,
               taken.contains(where: { near($0, check) }) || kept.contains(where: { $0.isOpen && near($0, check) }) { continue }
            kept.append(check)
        }
        return kept
    }

    /// A question that stands, with the time it is asked from: its round's
    /// start, so questions that fall due within `roundSpan` are asked together.
    struct Question { var check: PainCheck; var askAt: Date }

    /// Every standing question of the active injuries around now: the last
    /// three days and the next `days`.
    func questions(days: Int = 9) -> [Question] {
        let time = clock
        let from = time.addingTimeInterval(-3 * 86_400), to = time.addingTimeInterval(Double(days + 1) * 86_400)
        let active = Set(injuries.filter(\.isActive).map(\.id))
        let near = checks.filter { $0.dueAt >= from && $0.dueAt <= to && active.contains($0.injuryID) }
            + dailyChecks(from: Day(time, in: localZone).adding(-1), days: days + 1)
        var all: [Question] = []
        for (_, group) in Dictionary(grouping: near, by: \.injuryID) {
            all += AppModel.standing(group).map { check in
                // One answered early, with its round, counts from when it was answered.
                Question(check: check, askAt: min(check.dueAt, check.answeredAt ?? check.skippedAt ?? check.dueAt))
            }
        }
        all.sort { ($0.check.dueAt, $0.check.id) < ($1.check.dueAt, $1.check.id) }
        // Rounds: open questions not yet lapsed, each within `roundSpan` of the round's first.
        var start: Date?
        for i in all.indices where all[i].check.isOpen
            && time.timeIntervalSince(all[i].check.dueAt) <= AppModel.window(all[i].check.moment) {
            let due = all[i].check.dueAt
            if let s = start, due.timeIntervalSince(s) <= PainSchedule.roundSpan { all[i].askAt = s } else { start = due }
        }
        return all
    }

    /// The questions to answer now: at most one for each injury, the latest
    /// whose time has come. An earlier one it replaces, or one left too long,
    /// drops off the list and stays recorded as missing, never as zero.
    public var dueChecks: [PainCheck] {
        _ = tick
        let time = clock
        var latest: [String: PainCheck] = [:]
        for question in questions(days: 1) where question.askAt <= time {
            if let held = latest[question.check.injuryID], held.dueAt > question.check.dueAt { continue }
            latest[question.check.injuryID] = question.check
        }
        return latest.values
            .filter { $0.isOpen && time.timeIntervalSince($0.dueAt) <= AppModel.window($0.moment) }
            .sorted { ($0.dueAt, $0.id) < ($1.dueAt, $1.id) }
    }

    /// Questions still to come: those stored, and the morning questions of the next week.
    public var upcomingChecks: [PainCheck] {
        _ = tick
        let time = clock
        return questions(days: 8).filter { $0.check.isOpen && $0.askAt > time }.map(\.check)
    }

    /// The follow-up questions a finished workout calls for: those whose time
    /// has not already passed (as after a workout is edited later) and that
    /// were not already answered or skipped for this workout. Questions that
    /// double another session's are stored all the same and merged when read
    /// (`standing`), so deleting that other session loses nothing.
    func newChecks(for workout: Workout, sets: [WorkoutSet], end: Date) -> [PainCheck] {
        let time = clock
        var out: [PainCheck] = []
        for injury in schedule.injuriesLoaded(by: sets, injuries: injuries, library: library) {
            for check in schedule.checks(for: injury, workout: workout, endedAt: end) {
                guard time.timeIntervalSince(check.dueAt) <= AppModel.window(check.moment) else { continue }
                let done = checks.contains {
                    $0.workoutID == workout.id && $0.injuryID == injury.id && $0.moment == check.moment && !$0.isOpen
                }
                if !done { out.append(check) }
            }
        }
        return out
    }

    /// The injury's most recent answer to a question. A flare-up logged in
    /// between is a reading of a bad moment, not of how the injury is.
    public func lastReading(injuryID: String) -> PainCheck? {
        checks.filter { $0.injuryID == injuryID && $0.pain != nil && $0.moment != .flare }
            .max { ($0.answeredAt ?? $0.dueAt) < ($1.answeredAt ?? $1.dueAt) }
    }

    /// The reading "unchanged" copies: the last one, if a number was entered
    /// for this injury within the last three days. Carried-over values alone
    /// do not keep it alive, so a number cannot repeat itself for weeks.
    func unchangedSource(injuryID: String) -> PainCheck? {
        let time = clock
        let entered = checks.contains {
            $0.injuryID == injuryID && $0.pain != nil && $0.moment != .flare && $0.source != PainCheck.unchanged
                && time.timeIntervalSince($0.answeredAt ?? $0.dueAt) <= AppModel.unchangedWindow
        }
        return entered ? lastReading(injuryID: injuryID) : nil
    }

    /// Everything to answer now, as one screen: a row for each injury.
    public var checkInRound: [CheckInItem] {
        dueChecks.compactMap { check in
            guard let injury = injuries.first(where: { $0.id == check.injuryID }) else { return nil }
            let workout = check.workoutID.flatMap { id in workouts.first { $0.id == id } }
            return CheckInItem(check: check, injury: injury, last: lastReading(injuryID: injury.id),
                               unchangedValue: unchangedSource(injuryID: injury.id)?.pain,
                               sessionPain: workout.flatMap { setPain(in: sets(of: $0), for: injury) })
        }.sorted { ($0.injury.label, $0.id) < ($1.injury.label, $1.id) }
    }

    /// The highest pain recorded on sets that load an injury (a tissue share of
    /// 0.25 or more, on its side), whether or not it is still active.
    func setPain(in sets: [WorkoutSet], for injury: Injury) -> Double? {
        var loaded = injury
        loaded.resolvedOn = nil
        return sets.filter { $0.pain != nil && !schedule.injuriesLoaded(by: [$0], injuries: [loaded], library: library).isEmpty }
            .compactMap(\.pain).max()
    }

    /// A question can be answered while it is still there: stored and not
    /// deleted, or a morning question not stored yet, and its injury exists.
    /// A screen left open must not bring back what was deleted meanwhile.
    func isLive(_ check: PainCheck) -> Bool {
        guard injuries.contains(where: { $0.id == check.injuryID }) else { return false }
        if let held = checks.first(where: { $0.id == check.id }) { return held.injuryID == check.injuryID }
        return check.workoutID == nil && check.moment == .baseline
            && check.id.hasPrefix(AppModel.dailyCheckID(injuryID: check.injuryID, day: check.dueDay))
    }

    /// Saves several answers at once.
    public func answer(_ entries: [(check: PainCheck, pain: Double, type: PainType?, notes: String)]) {
        let time = clock
        var saved: [PainCheck] = [], refused: String?
        for entry in entries {
            guard let clean = AppModel.cleanPain(entry.pain) else { refused = "That pain value is not a number."; continue }
            guard isLive(entry.check) else { refused = "That question is no longer there."; continue }
            var check = entry.check
            check.pain = clean; check.painType = entry.type; check.notes = entry.notes
            check.source = nil; check.skippedAt = nil
            check.answeredAt = time; check.updatedAt = time
            saved.append(check)
        }
        if !saved.isEmpty {
            attempt { try storeChecks(saved) }
            reload()
        }
        if let refused { noteError(refused) }
    }

    /// Answers each question with the injury's reading before it: the person
    /// says nothing has changed. The value is marked as carried over, so it is
    /// never mistaken for a number they entered. A question about an injury
    /// with no recent reading cannot be answered this way and is returned.
    @discardableResult
    public func answerUnchanged(_ questions: [PainCheck]) -> [PainCheck] {
        let time = clock
        var saved: [PainCheck] = [], left: [PainCheck] = []
        for var check in questions {
            guard isLive(check), let last = unchangedSource(injuryID: check.injuryID), let pain = last.pain else {
                left.append(check); continue
            }
            check.pain = pain; check.painType = last.painType; check.notes = ""
            check.source = PainCheck.unchanged; check.skippedAt = nil
            check.answeredAt = time; check.updatedAt = time
            saved.append(check)
        }
        if !saved.isEmpty {
            attempt { try storeChecks(saved) }
            reload()
        }
        return left
    }

    /// Takes questions off the list unanswered. The readings stay missing.
    public func skip(_ questions: [PainCheck]) {
        let time = clock
        let skipped = questions.filter { $0.isOpen && isLive($0) }.map { check -> PainCheck in
            var check = check
            check.skippedAt = time; check.updatedAt = time
            return check
        }
        guard !skipped.isEmpty else { return }
        attempt { try storeChecks(skipped) }
        reload()
    }

    /// Records pain felt now, outside any schedule, for one injury or several.
    public func logPain(_ readings: [(injury: Injury, pain: Double, type: PainType?)], context: String = "",
                        notes: String = "") {
        let time = clock
        let saved = readings.compactMap { reading -> PainCheck? in
            guard let clean = AppModel.cleanPain(reading.pain) else { return nil }
            var check = PainCheck(injuryID: reading.injury.id, workoutID: nil, moment: .flare, dueAt: time,
                                  zone: localZone, updatedAt: time)
            check.pain = clean; check.painType = reading.type; check.notes = notes
            let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
            check.context = trimmed.isEmpty ? nil : trimmed
            check.answeredAt = time
            return check
        }
        guard !saved.isEmpty else { return }
        attempt { try storeChecks(saved) }
        reload()
    }

    /// One reminder for each round of questions still to come.
    public var reminderRounds: [ReminderRound] {
        var rounds: [Date: [PainCheck]] = [:]
        for question in questions(days: 8) where question.check.isOpen && question.askAt > clock {
            // One row for each injury: a second question about it in the same round adds nothing.
            if rounds[question.askAt]?.contains(where: { $0.injuryID == question.check.injuryID }) == true { continue }
            rounds[question.askAt, default: []].append(question.check)
        }
        return rounds.keys.sorted().compactMap { fireAt in
            let round = rounds[fireAt] ?? []
            let labels = round.compactMap { check in injuries.first { $0.id == check.injuryID }?.label }.sorted()
            guard !labels.isEmpty else { return nil }
            var moments: [PainCheckMoment] = []
            for check in round where !moments.contains(check.moment) { moments.append(check.moment) }
            return ReminderRound(id: "round:\(Stamp.millis(fireAt))", fireAt: fireAt,
                                 checkIDs: round.map(\.id), injuryLabels: labels, moments: moments)
        }
    }

    /// How each injury a workout loaded went afterwards. Readings are taken by
    /// time, whichever session or morning prompted them, since one reading
    /// serves every session before it.
    public func settling(for workout: Workout) -> [SessionSettling] {
        guard let end = workout.end else { return [] }
        let loaded = schedule.injuriesLoaded(by: sets(of: workout), injuries: injuries.map { injury in
            // An injury since resolved was still loaded by this session.
            var injury = injury
            if let resolved = injury.resolvedOn, resolved >= workout.startDay { injury.resolvedOn = nil }
            return injury
        }, library: library)
        let until = end.addingTimeInterval(60 * 3600)
        return loaded.compactMap { loadedInjury in
            guard let injury = injuries.first(where: { $0.id == loadedInjury.id }) else { return nil }
            let mine = checks.filter { $0.injuryID == injury.id }
            let window = mine.filter { $0.dueAt >= end && $0.dueAt <= until }
            // Questions that stand (two sessions' questions at one hour are one) and flare-ups logged in between.
            let after = AppModel.standing(window) + window.filter { $0.moment == .flare }
            let readings = after.filter { $0.pain != nil }.sorted { $0.dueAt < $1.dueAt }
            // Going in: the last question due before the session began and answered before it ended.
            // A reading the person logged themselves in the quarter hour before is one too: logged on the way in,
            // it says how it was going in. A flare-up earlier in the day stays a bad moment, not a level.
            let before = mine.filter { check in
                guard check.pain != nil, let at = check.answeredAt else { return false }
                if check.moment == .flare {
                    return check.dueAt <= workout.start && workout.start.timeIntervalSince(check.dueAt) <= 15 * 60
                }
                return check.dueAt <= workout.start && at <= end && workout.start.timeIntervalSince(check.dueAt) <= 3 * 86_400
            }.max { $0.dueAt < $1.dueAt }
            let baseline = before?.pain
            return SessionSettling(injury: injury, baseline: baseline, readings: readings,
                                   during: setPain(in: sets(of: workout), for: injury),
                                   asked: after.filter { $0.moment != .flare }.count,
                                   summary: baseline.map { SettlingSummary(checks: after, baseline: $0, sessionEnd: end) })
        }.sorted { $0.injury.label < $1.injury.label }
    }
}
