import Foundation

/// One day of an injury's story: what its tissues were asked to do and how it felt.
public struct InjuryDay: Identifiable, Equatable, Sendable {
    public let day: Day
    /// Effective reps on the injured side that day: the most loaded of the
    /// injury's tissues, walking included.
    public let load: Double
    /// The same for the other side. Nil for an injury on both sides.
    public let otherLoad: Double?
    /// True when a logged session loaded the injury that day (not walking alone).
    public let trained: Bool
    /// Lowest and highest answer to a question that day. Nil when none was answered.
    public let painLow: Double?
    public let painHigh: Double?
    /// The worst flare-up logged that day, if any.
    public let flare: Double?
    /// The highest pain recorded on a set that loaded the injury that day:
    /// pain under load, which is not the same measure as an answer to a question.
    public let setPain: Double?
    public var id: Day { day }
}

/// What one exercise did for an injury over a report's period.
public struct InjuryExerciseLine: Equatable, Sendable {
    public let exercise: String
    public let sessions: Int
    /// The first and the latest top set on the injured side in the period, as text ("20 lb x 12").
    public let first: String
    public let latest: String
    /// The latest top set on the other side, when it was logged too.
    public let other: String?
    public let maxPain: Double?
}

/// An injury's last weeks in numbers, for a physical therapist or a doctor.
public struct InjuryReport: Equatable, Sendable {
    public let injury: Injury
    public let start: Day
    public let end: Day
    public let days: [InjuryDay]
    /// Mean of the morning and daily answers in the period's last 7 days and
    /// in the 7 before them. Nil with no answers.
    public let recentPain: Double?
    public let earlierPain: Double?
    public let answered: Int
    public let asked: Int
    public let flares: [PainCheck]
    /// Effective reps per week on the injured side, oldest first, and on the other side.
    public let weeklyLoad: [Double]
    public let weeklyOtherLoad: [Double]?
    public let exercises: [InjuryExerciseLine]
    public let symmetry: [SymmetryRow]
    /// Sessions that loaded the injury and have a reading before and a delayed one after.
    public let sessionsFollowed: Int
    public let sessionsLoading: Int
    /// Of those followed: pain rose more than a point above the reading going in.
    public let sessionsRaisedPain: Int
    /// Of those that rose: back within half a point by the last reading.
    public let sessionsSettled: Int
    public let medianHoursToSettle: Double?
}

extension AppModel {
    /// Day by day for the `days` days ending today, oldest first.
    public func timeline(for injury: Injury, days: Int = 42) -> [InjuryDay] {
        let span = max(1, days)
        let window = tissueDays(last: span)
        let tissues = Set(injury.tissues)
        let injuredSides = injury.side.bodySides
        let otherSide: Side? = injury.side == .left ? .right : injury.side == .right ? .left : nil
        var load: [Day: Double] = [:], other: [Day: Double] = [:]
        for d in window.days where tissues.contains(d.tissue) {
            if injuredSides.contains(d.side) { load[d.day] = max(load[d.day] ?? 0, d.dose) }
            if d.side == otherSide { other[d.day] = max(other[d.day] ?? 0, d.dose) }
        }
        var trained = Set<Day>(), underLoad: [Day: Double] = [:]
        for workout in workouts where window.end.days(since: workout.startDay) < span {
            var loaded = injury
            loaded.resolvedOn = nil
            let sets = sets(of: workout)
            if !schedule.injuriesLoaded(by: sets, injuries: [loaded], library: library).isEmpty {
                trained.insert(workout.startDay)
                if let pain = setPain(in: sets, for: injury) {
                    underLoad[workout.startDay] = max(underLoad[workout.startDay] ?? 0, pain)
                }
            }
        }
        var answers: [Day: [Double]] = [:], flares: [Day: Double] = [:]
        for check in checks where check.injuryID == injury.id {
            guard let pain = check.pain else { continue }
            let day = Day(check.answeredAt ?? check.dueAt, in: localZone)
            if check.moment == .flare { flares[day] = max(flares[day] ?? 0, pain) } else { answers[day, default: []].append(pain) }
        }
        return (0..<span).map { back in
            let day = window.end.adding(back - span + 1)
            return InjuryDay(day: day, load: load[day] ?? 0, otherLoad: otherSide == nil ? nil : (other[day] ?? 0),
                             trained: trained.contains(day), painLow: answers[day]?.min(), painHigh: answers[day]?.max(),
                             flare: flares[day], setPain: underLoad[day])
        }
    }

    /// A load as the person reads it: in the set's own unit, with what the number means.
    func describe(_ set: WorkoutSet) -> String {
        func number(_ value: Double) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        }
        var load: String
        switch set.convention {
        case .bodyweight: load = "body weight"
        case .bodyweightPlus: load = set.loadValue.map { "body weight + \(number($0)) \(set.loadUnit.rawValue)" } ?? "body weight"
        case .perHand: load = set.loadValue.map { "\(number($0)) \(set.loadUnit.rawValue) each hand" } ?? "no load entered"
        case .total: load = set.loadValue.map { "\(number($0)) \(set.loadUnit.rawValue)" } ?? "no load entered"
        }
        if set.kind == .hold { return "\(load), held \(number(set.holdSeconds ?? 0)) s" }
        return "\(load) x \(number(set.reps ?? 0))"
    }

    /// The injury's last `days` days in numbers.
    public func report(for injury: Injury, days: Int = 28) -> InjuryReport {
        let span = max(7, days)
        let line = timeline(for: injury, days: span)
        let end = line.last?.day ?? Day(clock, in: localZone), start = end.adding(1 - span)
        let inPeriod = { (day: Day) in day >= start && day <= end }
        let mine = checks.filter { $0.injuryID == injury.id && inPeriod(Day($0.answeredAt ?? $0.dueAt, in: localZone)) }
        let questions = AppModel.standing(mine).filter { $0.dueAt <= clock }
        // "How is it" away from a session: the morning and daily answers.
        func resting(_ from: Day, _ to: Day) -> Double? {
            let values = questions.filter { $0.moment == .baseline || $0.moment == .nextMorning }
                .filter { check in
                    let day = Day(check.answeredAt ?? check.dueAt, in: localZone)
                    return day >= from && day <= to
                }.compactMap(\.pain)
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        let weeks = stride(from: 0, to: span, by: 7).map { offset -> ArraySlice<InjuryDay> in
            line[max(0, line.count - span + offset)..<min(line.count, line.count - span + offset + 7)]
        }
        // Exercises that load the injury, on the injured side.
        let tissues = Set(injury.tissues)
        let finished = Dictionary(workouts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var names: [String: String] = [:]
        for set in storedSets where finished[set.workoutID] != nil && inPeriod(set.workoutDay)
            && !set.side.bodySides.filter({ injury.side.bodySides.contains($0) }).isEmpty {
            let loads = library.pattern(set.pattern)?.links.contains { $0.share >= 0.25 && tissues.contains($0.tissue) } ?? false
            if loads { names[AppModel.normal(set.exercise)] = set.exercise }
        }
        let exercises = names.values.sorted().compactMap { name -> InjuryExerciseLine? in
            let history = exerciseHistory(name).filter { inPeriod($0.day) }
            let own = history.filter { $0.side == injury.side || $0.side == .both }
            guard let first = own.first, let latest = own.last else { return nil }
            func top(_ session: ExerciseSession) -> String {
                (session.topSet ?? session.sets.max { ($0.holdSeconds ?? 0) < ($1.holdSeconds ?? 0) }).map(describe) ?? "no working set"
            }
            let otherSide = history.last { $0.side != injury.side && $0.side != .both }
            return InjuryExerciseLine(exercise: name, sessions: Set(own.map(\.workoutID)).count, first: top(first),
                                      latest: top(latest), other: otherSide.map(top),
                                      maxPain: own.compactMap(\.maxPain).max())
        }
        // How sessions were tolerated.
        var followed = 0, loading = 0, raised = 0, settled = 0, hours: [Double] = []
        for workout in workouts where inPeriod(workout.startDay) {
            guard let mine = settling(for: workout).first(where: { $0.injury.id == injury.id }) else { continue }
            loading += 1
            guard let baseline = mine.baseline, let summary = mine.summary,
                  mine.readings.contains(where: { $0.moment != .afterSession }) else { continue }
            followed += 1
            if (summary.peak ?? 0) > baseline + 1 {
                raised += 1
                if let h = summary.hoursToSettle { settled += 1; hours.append(h) }
            }
        }
        hours.sort()
        let median = hours.isEmpty ? nil : (hours.count % 2 == 1 ? hours[hours.count / 2]
                                            : (hours[hours.count / 2 - 1] + hours[hours.count / 2]) / 2)
        return InjuryReport(
            injury: injury, start: start, end: end, days: line,
            recentPain: resting(end.adding(-6), end), earlierPain: resting(end.adding(-13), end.adding(-7)),
            answered: questions.filter { $0.pain != nil }.count, asked: questions.count,
            flares: mine.filter { $0.moment == .flare }.sorted { $0.dueAt < $1.dueAt },
            weeklyLoad: weeks.map { $0.reduce(0) { $0 + $1.load } },
            weeklyOtherLoad: injury.side == .both ? nil : weeks.map { $0.reduce(0) { $0 + ($1.otherLoad ?? 0) } },
            exercises: exercises, symmetry: symmetry(for: injury, days: span),
            sessionsFollowed: followed, sessionsLoading: loading, sessionsRaisedPain: raised,
            sessionsSettled: settled, medianHoursToSettle: median)
    }

    /// The report as plain Markdown, to share or print. It states what was
    /// logged, with the counts behind each number, and draws no conclusions.
    public func reportText(for injury: Injury, days: Int = 28) -> String {
        let r = report(for: injury, days: days)
        func n(_ value: Double) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        }
        func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
        let side = injury.side == .both ? "both sides" : "\(injury.side.rawValue) side"
        let tissues = injury.tissues.compactMap { library.tissue($0)?.name }.joined(separator: ", ")
        var out: [String] = []
        out.append("# \(injury.label)")
        out.append("")
        var facts = "\(side.prefix(1).uppercased() + side.dropFirst()); \(tissues.isEmpty ? "tissues not set" : tissues). "
        facts += "Began \(injury.onsetPrecision == .day ? "on" : "around") \(injury.onset)"
        facts += injury.resolvedOn.map { ", marked resolved \($0)." } ?? ", \(max(0, r.end.days(since: injury.onset)) / 7) weeks before this report."
        out.append(facts)
        if !injury.mechanism.isEmpty { out.append("How it happened: \(injury.mechanism)") }
        out.append("Period: \(r.start) to \(r.end) (\(r.days.count) days).")
        out.append("")
        out.append("## Pain (0 to 10)")
        let underLoad = r.days.compactMap { day in day.setPain.map { (day.day, $0) } }
        if r.asked == 0 && r.flares.isEmpty {
            out.append("No pain questions were answered in this period.")
        } else {
            out.append("- Questions answered: \(r.answered) of \(r.asked).")
            switch (r.recentPain, r.earlierPain) {
            case let (recent?, earlier?):
                out.append("- Morning and daily readings, last 7 days: mean \(n(recent)). The 7 days before: mean \(n(earlier)).")
            case let (recent?, nil):
                out.append("- Morning and daily readings, last 7 days: mean \(n(recent)). None in the 7 days before.")
            default:
                out.append("- No morning or daily readings in the last 7 days.")
            }
            let highs = r.days.compactMap { day in day.painHigh.map { (day.day, $0) } }
            if let worst = highs.max(by: { $0.1 < $1.1 }) { out.append("- Highest answer: \(n(worst.1)) on \(worst.0).") }
            if r.flares.isEmpty {
                out.append("- Flare-ups logged: none.")
            } else {
                out.append("- Flare-ups logged: \(r.flares.count).")
                for flare in r.flares {
                    let about = [flare.context, flare.painType?.rawValue, flare.notes.isEmpty ? nil : flare.notes]
                        .compactMap { $0 }.joined(separator: "; ")
                    out.append("  - \(Day(flare.dueAt, in: localZone)): \(n(flare.pain ?? 0))\(about.isEmpty ? "" : " (\(about))")")
                }
            }
        }
        if let worst = underLoad.max(by: { $0.1 < $1.1 }) {
            out.append("- Pain recorded during sets that load it: on \(underLoad.count) day\(underLoad.count == 1 ? "" : "s"), highest \(n(worst.1)) on \(worst.0).")
        }
        out.append("")
        out.append("## Load on the injured tissue")
        out.append("In effective reps: reps at the usual weight, heavier sets counting more. Daily steps are included for leg tissues.")
        out.append("")
        out.append(r.weeklyOtherLoad == nil ? "| Week ending | Load |" : "| Week ending | Injured side | Other side |")
        out.append(r.weeklyOtherLoad == nil ? "|---|---|" : "|---|---|---|")
        for (i, load) in r.weeklyLoad.enumerated() {
            let ending = r.start.adding(min(r.days.count, (i + 1) * 7) - 1)
            if let other = r.weeklyOtherLoad { out.append("| \(ending) | \(n(load)) | \(n(other[i])) |") }
            else { out.append("| \(ending) | \(n(load)) |") }
        }
        out.append("")
        out.append("## Exercises that load it")
        if r.exercises.isEmpty {
            out.append("None logged in this period.")
        } else {
            for line in r.exercises {
                var text = "- \(line.exercise): \(line.sessions) session\(line.sessions == 1 ? "" : "s"). "
                text += line.sessions == 1 ? "Top set \(line.latest)." : "Top set went from \(line.first) to \(line.latest)."
                if let other = line.other { text += " Other side, latest: \(other)." }
                if let pain = line.maxPain { text += " Highest pain during a set: \(n(pain))." }
                out.append(text)
            }
        }
        let compared = r.symmetry.filter { $0.ratio != nil }
        if !compared.isEmpty {
            out.append("")
            out.append("## Injured side against the other")
            for row in compared {
                guard let ratio = row.ratio else { continue }
                let what = row.latest.measure == .e1RM ? "estimated one-rep max"
                    : row.latest.measure == .holdLoad ? "load held x seconds" : "seconds held"
                var text = "- \(row.exercise): \(percent(ratio)) of the other side (\(what)) on \(row.latest.day)"
                if let first = row.firstRatio { text += "; \(percent(first)) at the start of the period" }
                out.append(text + ".")
            }
        }
        out.append("")
        out.append("## After sessions")
        if r.sessionsLoading == 0 {
            out.append("No session loaded this injury in the period.")
        } else {
            out.append("- Sessions that loaded it: \(r.sessionsLoading). With a reading before and a later one after: \(r.sessionsFollowed).")
            if r.sessionsFollowed > 0 {
                out.append("- Pain rose more than 1 point above the reading before in \(r.sessionsRaisedPain) of \(r.sessionsFollowed).")
                if r.sessionsRaisedPain > 0 {
                    var text = "- Of those, back within half a point by the last reading: \(r.sessionsSettled)"
                    if let median = r.medianHoursToSettle { text += ", after a median of \(n(median)) hours" }
                    out.append(text + ".")
                }
            }
        }
        if !injury.notes.isEmpty {
            out.append("")
            out.append("## Notes")
            out.append(injury.notes)
        }
        out.append("")
        out.append("Written by Rehabit from what was logged. It reports numbers and counts; it is not an assessment or advice.")
        return out.joined(separator: "\n")
    }
}
