import Foundation

/// Where nightly recovery values and steps come from. Apple Health implements
/// this on iPhone and Health Connect would on Android; nothing else in the app
/// knows which one it is talking to.
public protocol HealthSource: Sendable {
    /// A short name stored with each value, such as "apple_health".
    var name: String { get }
    /// Asks the person for read access. Returns false if it is unavailable or refused.
    func requestAccess() async throws -> Bool
    /// One value per day and metric in the range. A day with no reading is
    /// simply absent: a missing night must never be stored as zero.
    func dailyMetrics(from: Day, through: Day) async throws -> [DailyMetric]
}

public enum MetricName {
    public static let hrv = "hrv_ms"
    public static let restingHeartRate = "resting_hr"
    public static let sleepMinutes = "sleep_minutes"
    public static let steps = "steps"
}
