import Foundation

/// One day of the history calendar.
public struct CalendarDay: Identifiable, Equatable, Sendable {
    public let day: Day
    /// Finished workouts begun that day, earliest first.
    public let workouts: [Workout]
    /// Working sets with something done in them.
    public let workingSets: Int
    /// Highest answer to a pain question that day, over every injury. Nil when none was answered.
    public let painHigh: Double?
    /// Highest pain recorded on a set that day. Nil when none was.
    public let setPain: Double?
    /// Flare-ups logged that day.
    public let flares: Int
    public var id: Day { day }
    public var isEmpty: Bool { workouts.isEmpty && painHigh == nil && flares == 0 }
}

extension AppModel {
    /// Every day from `first` to `last`, in order, with what was logged on it.
    /// At most 400 days: a calendar asks for a month or a year.
    public func calendar(from first: Day, to last: Day) -> [CalendarDay] {
        guard last >= first else { return [] }
        let last = min(last, first.adding(399))
        var byDay: [Day: [Workout]] = [:]
        for workout in workouts where workout.startDay >= first && workout.startDay <= last {
            byDay[workout.startDay, default: []].append(workout)
        }
        var sets: [String: (count: Int, pain: Double?)] = [:]
        let wanted = Set(byDay.values.flatMap { $0.map(\.id) })
        for set in storedSets where wanted.contains(set.workoutID) {
            var entry = sets[set.workoutID] ?? (0, nil)
            if !set.isWarmup, (set.count ?? 0) > 0 { entry.count += 1 }
            if let pain = set.pain { entry.pain = max(entry.pain ?? pain, pain) }
            sets[set.workoutID] = entry
        }
        var answers: [Day: Double] = [:], flares: [Day: Int] = [:]
        for check in checks where check.pain != nil {
            let day = Day(check.answeredAt ?? check.dueAt, in: localZone)
            guard day >= first, day <= last, let pain = check.pain else { continue }
            if check.moment == .flare { flares[day, default: 0] += 1 }
            else { answers[day] = max(answers[day] ?? pain, pain) }
        }
        return (0...last.days(since: first)).map { offset in
            let day = first.adding(offset)
            let workouts = (byDay[day] ?? []).sorted { $0.start < $1.start }
            return CalendarDay(day: day, workouts: workouts,
                               workingSets: workouts.reduce(0) { $0 + (sets[$1.id]?.count ?? 0) },
                               painHigh: answers[day], setPain: workouts.compactMap { sets[$0.id]?.pain }.max(),
                               flares: flares[day] ?? 0)
        }
    }

    /// The days of one month. Empty for a month that does not exist.
    public func calendar(year: Int, month: Int) -> [CalendarDay] {
        guard (1...12).contains(month) else { return [] }
        let first = Day(year: year, month: month, day: 1)
        let next = month == 12 ? Day(year: year + 1, month: 1, day: 1) : Day(year: year, month: month + 1, day: 1)
        return calendar(from: first, to: next.adding(-1))
    }
}
