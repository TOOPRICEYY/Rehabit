import Foundation
import Observation
import RehabitCore
import UserNotifications

/// Local notifications for the delayed pain check-ins.
enum Reminders {
    /// Makes the pending reminders match the questions still to come: those no
    /// longer wanted (answered, or their workout or injury is gone) are
    /// withdrawn, and the rest are scheduled. Permission is only asked for when
    /// there is something to remind about.
    static func sync(_ checks: [PainCheck], injuries: [Injury]) {
        let center = UNUserNotificationCenter.current()
        let wanted = Set(checks.map(\.id))
        center.getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { !wanted.contains($0) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
        guard !checks.isEmpty else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for check in checks {
                let delay = check.dueAt.timeIntervalSinceNow
                guard delay > 1 else { continue }
                let content = UNMutableNotificationContent()
                let label = injuries.first { $0.id == check.injuryID }?.label ?? "your injury"
                content.title = "How is \(label)?"
                content.body = "\(Format.moment(check.moment)). A ten-second pain check."
                content.sound = .default
                // The check's id is the notification's id, so scheduling twice replaces it.
                center.add(UNNotificationRequest(
                    identifier: check.id, content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)))
            }
        }
    }
}

/// Opens the Check-ins tab when a reminder is tapped, and lets a reminder show
/// while the app is already open.
@Observable
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    /// Counts taps on reminders; the root view watches it.
    private(set) var opened = 0

    func install() { UNUserNotificationCenter.current().delegate = self }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.opened += 1 }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
