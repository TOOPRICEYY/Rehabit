import Foundation

/// When to ask about pain after a session. Pain from loading a healing tissue
/// often peaks hours later or the next morning, so one reading at the gym
/// misses the part that says whether the load was tolerated.
public struct PainSchedule: Sendable {
    public var eveningHoursAfter = 6.0
    public var morningHour = 8
    /// Evening checks are not asked later than this local hour; the morning check covers it.
    public var latestEveningHour = 22
    public var zone: TimeZone

    public init(zone: TimeZone = .current) { self.zone = zone }

    /// The injuries a workout loaded: active, and sharing a tissue and a side with any set.
    public func injuriesLoaded(by sets: [WorkoutSet], injuries: [Injury], library: Library = .standard,
                               minShare: Double = 0.25) -> [Injury] {
        injuries.filter { injury in
            injury.isActive && sets.contains { set in
                let sides = set.side.bodySides
                guard injury.side == .both || sides.contains(injury.side) else { return false }
                return (library.pattern(set.pattern)?.links ?? [])
                    .contains { $0.share >= minShare && injury.tissues.contains($0.tissue) }
            }
        }
    }

    /// The checks to schedule for one injury when a workout ends.
    public func checks(for injury: Injury, workout: Workout, endedAt end: Date) -> [PainCheck] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func check(_ moment: PainCheckMoment, _ due: Date) -> PainCheck {
            PainCheck(injuryID: injury.id, workoutID: workout.id, moment: moment, dueAt: due, zone: zone,
                      updatedAt: end)
        }
        var out = [check(.afterSession, end)]
        let evening = end.addingTimeInterval(eveningHoursAfter * 3600)
        let sameDay = calendar.isDate(evening, inSameDayAs: end)
        if sameDay && calendar.component(.hour, from: evening) < latestEveningHour {
            out.append(check(.evening, evening))
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end))!
        if let morning = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: tomorrow) {
            out.append(check(.nextMorning, morning))
        }
        out.append(check(.hours24, end.addingTimeInterval(24 * 3600)))
        out.append(check(.hours48, end.addingTimeInterval(48 * 3600)))
        return out
    }
}

/// How an injury's pain settled after one session: the readings in order, and
/// how long it took to come back to the reading before the session.
public struct SettlingSummary: Equatable, Sendable {
    public let peak: Double?
    /// Hours from the end of the session to the first reading from which pain
    /// stayed near baseline. Nil if it had not settled by the last answer.
    public let hoursToSettle: Double?
    public let answered: Int
    public let asked: Int

    /// `baseline` is the pain level the person had going in (a daily baseline or
    /// the previous settled value). Settled means back to within half a point of it.
    public init(checks: [PainCheck], baseline: Double, sessionEnd: Date) {
        let answeredChecks = checks.filter { $0.pain != nil }.sorted { $0.dueAt < $1.dueAt }
        asked = checks.count
        answered = answeredChecks.count
        peak = answeredChecks.compactMap(\.pain).max()
        // Settled at the first reading that is back near baseline with no later reading above it.
        var settledAt: Date?
        for (i, check) in answeredChecks.enumerated() {
            let rest = answeredChecks[i...].compactMap(\.pain)
            if rest.allSatisfy({ $0 <= baseline + 0.5 }) {
                settledAt = check.answeredAt ?? check.dueAt
                break
            }
        }
        hoursToSettle = settledAt.map { max(0, $0.timeIntervalSince(sessionEnd) / 3600) }
    }
}
