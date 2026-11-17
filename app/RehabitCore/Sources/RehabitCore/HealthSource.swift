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
    /// Overnight HRV as Garmin reports it (based on beat-to-beat differences, RMSSD).
    public static let hrv = "hrv_ms"
    /// HRV as Apple Health reports it (SDNN). It is a different measure from the
    /// one above and runs on a different scale, so the two are never mixed in
    /// one baseline.
    public static let hrvSDNN = "hrv_sdnn_ms"
    public static let restingHeartRate = "resting_hr"
    public static let sleepMinutes = "sleep_minutes"
    public static let steps = "steps"
    /// Body weight in kilograms on a day, from a scale, a watch or typed in.
    public static let bodyMass = "body_mass_kg"
    /// The source name of a value the person typed in. It wins over a device's value for the same day.
    public static let manualSource = "manual"
}
