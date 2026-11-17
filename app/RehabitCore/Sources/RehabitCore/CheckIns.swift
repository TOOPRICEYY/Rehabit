import Foundation

/// One question on the check-in screen, with what is needed to answer it in a tap.
public struct CheckInItem: Identifiable, Equatable, Sendable {
    public let check: PainCheck
    public let injury: Injury
    /// The injury's most recent reading, shown beside the question and copied
    /// by "unchanged". Nil if it has never been answered.
    public let last: PainCheck?
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
    /// The reading going in: the last one in the three days before the session. Nil if there was none.
    public let baseline: Double?
    /// Readings from the end of the session to 60 hours after, in order, whatever prompted them.
    public let readings: [PainCheck]
    /// Questions asked in that time, answered or not.
    public let asked: Int
    /// Nil without a baseline to settle back to.
    public let summary: SettlingSummary?
}

extension AppModel {
    /// The id of a day's morning question for an injury. Fixed, so the same
    /// question answered on two devices is one record.
    static func dailyCheckID(injuryID: String, day: Day) -> String { "daily:\(injuryID):\(day)" }

    /// The morning questions for a run of days: one for each active injury,
    /// unless a follow-up already falls close to that morning (it then serves
    /// as the day's reading) or the morning's question was answered or skipped.
    /// These are not stored until answered, so a year of ignored mornings
    /// leaves nothing behind.
    func dailyChecks(from first: Day, days: Int) -> [PainCheck] {
        guard profile.dailyCheckIn else { return [] }
        var out: [PainCheck] = []
        let stored = Set(checks.map(\.id))
        for offset in 0..<max(0, days) {
            let day = first.adding(offset)
            guard let due = schedule.morning(of: day) else { continue }
            for injury in injuries where injury.isActive && injury.earliestOnset <= day {
                let id = AppModel.dailyCheckID(injuryID: injury.id, day: day)
                guard !stored.contains(id), !checks.contains(where: {
                    $0.injuryID == injury.id && abs($0.dueAt.timeIntervalSince(due)) < PainSchedule.sameReading
                }) else { continue }
                out.append(PainCheck(id: id, injuryID: injury.id, workoutID: nil, moment: .baseline, dueAt: due,
                                     zone: localZone, updatedAt: due))
            }
        }
        return out
    }

    /// The follow-up questions a finished workout calls for. A question is left
    /// out when one already waiting for the same injury falls close to it (two
    /// sessions a day apart would otherwise both ask at the same hour), and
    /// when its time has already passed, as after a workout is edited later.
    func newChecks(for workout: Workout, sets: [WorkoutSet], end: Date) -> [PainCheck] {
        let time = clock
        var out: [PainCheck] = []
        for injury in schedule.injuriesLoaded(by: sets, injuries: injuries, library: library) {
            for check in schedule.checks(for: injury, workout: workout, endedAt: end) {
                guard time.timeIntervalSince(check.dueAt) <= AppModel.window(check.moment) else { continue }
                let covered = check.moment != .afterSession && checks.contains {
                    $0.injuryID == injury.id && $0.isOpen && $0.workoutID != workout.id
                        && abs($0.dueAt.timeIntervalSince(check.dueAt)) < PainSchedule.sameReading
                }
                if !covered { out.append(check) }
            }
        }
        return out
    }

    /// The injury's most recent reading.
    public func lastReading(injuryID: String) -> PainCheck? {
        checks.filter { $0.injuryID == injuryID && $0.pain != nil }
            .max { ($0.answeredAt ?? $0.dueAt) < ($1.answeredAt ?? $1.dueAt) }
    }

    /// Everything to answer now, as one screen: a row for each injury.
    public var checkInRound: [CheckInItem] {
        dueChecks.compactMap { check in
            guard let injury = injuries.first(where: { $0.id == check.injuryID }) else { return nil }
            return CheckInItem(check: check, injury: injury, last: lastReading(injuryID: injury.id))
        }.sorted { ($0.injury.label, $0.id) < ($1.injury.label, $1.id) }
    }

    /// Saves several answers at once.
    public func answer(_ entries: [(check: PainCheck, pain: Double, type: PainType?, notes: String)]) {
        let time = clock
        var saved: [PainCheck] = []
        for entry in entries {
            guard let clean = AppModel.cleanPain(entry.pain) else { continue }
            var check = entry.check
            check.pain = clean; check.painType = entry.type; check.notes = entry.notes
            check.source = nil; check.skippedAt = nil
            check.answeredAt = time; check.updatedAt = time
            saved.append(check)
        }
        guard !saved.isEmpty else { return }
        attempt { try storeChecks(saved) }
        reload()
    }

    /// Answers each question with the injury's reading before it: the person
    /// says nothing has changed. The value is marked as carried over, so it is
    /// never mistaken for a number they entered. A question about an injury
    /// with no earlier reading cannot be answered this way and is returned.
    @discardableResult
    public func answerUnchanged(_ questions: [PainCheck]) -> [PainCheck] {
        let time = clock
        var saved: [PainCheck] = [], left: [PainCheck] = []
        for var check in questions {
            guard let last = lastReading(injuryID: check.injuryID), let pain = last.pain else { left.append(check); continue }
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
        let skipped = questions.filter(\.isOpen).map { check -> PainCheck in
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

    /// One reminder for each cluster of questions still to come.
    public var reminderRounds: [ReminderRound] {
        var rounds: [[PainCheck]] = []
        for check in upcomingChecks {
            if let first = rounds.last?.first, check.dueAt.timeIntervalSince(first.dueAt) <= PainSchedule.roundSpan {
                // One row for each injury: a second question about it in the same round adds nothing.
                if !rounds[rounds.count - 1].contains(where: { $0.injuryID == check.injuryID }) {
                    rounds[rounds.count - 1].append(check)
                }
            } else {
                rounds.append([check])
            }
        }
        return rounds.compactMap { round in
            let labels = round.compactMap { check in injuries.first { $0.id == check.injuryID }?.label }.sorted()
            guard let first = round.first, !labels.isEmpty else { return nil }
            var moments: [PainCheckMoment] = []
            for check in round where !moments.contains(check.moment) { moments.append(check.moment) }
            return ReminderRound(id: "round:\(Stamp.millis(first.dueAt))", fireAt: first.dueAt,
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
            let after = mine.filter { $0.dueAt >= end && $0.dueAt <= until }
            let readings = after.filter { $0.pain != nil }.sorted { $0.dueAt < $1.dueAt }
            let before = mine.filter { check in
                guard check.pain != nil, let at = check.answeredAt else { return false }
                return at <= workout.start && workout.start.timeIntervalSince(at) <= 3 * 86_400
            }.max { ($0.answeredAt ?? $0.dueAt) < ($1.answeredAt ?? $1.dueAt) }
            let baseline = before?.pain
            return SessionSettling(injury: injury, baseline: baseline, readings: readings, asked: after.count,
                                   summary: baseline.map { SettlingSummary(checks: after, baseline: $0, sessionEnd: end) })
        }.sorted { $0.injury.label < $1.injury.label }
    }
}
