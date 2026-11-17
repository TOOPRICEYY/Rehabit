import Foundation
import Observation
import RehabitCore
import UserNotifications

/// Local notifications for the pain check-ins: one per round of questions,
/// not one per question.
enum Reminders {
    static let thread = "pain-check-ins"

    /// Makes the pending reminders match the rounds still to come: those no
    /// longer wanted are withdrawn and the rest scheduled (a round's id is the
    /// notification's id, so scheduling twice replaces it). Permission is only
    /// asked for when there is something to remind about.
    static func sync(_ rounds: [ReminderRound]) {
        let center = UNUserNotificationCenter.current()
        let wanted = Set(rounds.map(\.id))
        center.getPendingNotificationRequests { pending in
            let stale = pending.map(\.identifier).filter { !wanted.contains($0) }
            center.removePendingNotificationRequests(withIdentifiers: stale)
        }
        guard !rounds.isEmpty else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            for round in rounds {
                let delay = round.fireAt.timeIntervalSinceNow
                guard delay > 1 else { continue }
                let content = UNMutableNotificationContent()
                content.title = round.title
                content.body = round.body
                content.sound = .default
                content.threadIdentifier = thread
                center.add(UNNotificationRequest(
                    identifier: round.id, content: content,
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
