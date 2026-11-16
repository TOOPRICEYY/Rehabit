import Foundation
import RehabitCore
import UserNotifications

/// Local notifications for the delayed pain check-ins.
enum Reminders {
    static func schedule(_ checks: [PainCheck], injuries: [Injury]) {
        let center = UNUserNotificationCenter.current()
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
