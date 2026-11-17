import Foundation

/// A calendar date with no time or time zone, such as 2026-11-16.
///
/// Training load is counted per day. A session belongs to the day it started
/// on where the person was, and that must not shift if they later travel, so
/// the day is fixed when the record is made and stored as text.
public struct Day: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    /// Days since 1970-01-01.
    public let number: Int

    public init(number: Int) { self.number = number }

    public init(year: Int, month: Int, day: Int) {
        // Days-from-civil, proleptic Gregorian calendar.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        number = era * 146_097 + doe - 719_468
    }

    public init?(_ text: String) {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
        // 31 February would otherwise slide into March.
        guard components == (parts[0], parts[1], parts[2]) else { return nil }
    }

    /// The day a moment falls on in a given time zone.
    public init(_ date: Date, in zone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public var components: (year: Int, month: Int, day: Int) {
        let z = number + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    public var description: String {
        let c = components
        func pad(_ n: Int, _ width: Int) -> String {
            let s = String(n)
            return String(repeating: "0", count: max(0, width - s.count)) + s
        }
        return "\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2))"
    }

    /// The date as it is read: "Nov 3, 2026". The stored form stays 2026-11-03.
    public var readable: String {
        let c = components
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[c.month - 1]) \(c.day), \(c.year)"
    }

    /// Midnight at the start of this day in a time zone.
    public func start(in zone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = components
        return calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day))!
    }

    public func adding(_ days: Int) -> Day { Day(number: number + days) }
    public func days(since other: Day) -> Int { number - other.number }
    public static func < (a: Day, b: Day) -> Bool { a.number < b.number }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let day = Day(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not a date: \(text)"))
        }
        self = day
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
