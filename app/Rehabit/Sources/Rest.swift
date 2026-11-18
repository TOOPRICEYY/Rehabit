import AudioToolbox
import RehabitCore
import SwiftUI
import UserNotifications

/// The rest after a set marked done: time left, a quarter minute more or less
/// for this exercise from now on, and Skip.
struct RestReadout: View {
    @Environment(AppModel.self) private var model
    let rest: RestTimer
    let now: Date

    var body: some View {
        let left = rest.remaining(at: now)
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(left > 0 ? "Rest" : "Rest over").font(.caption2)
                    .foregroundStyle(left > 0 ? Color.secondary : Color.green).lineLimit(1)
                Text(Format.elapsed(left)).font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(left > 0 ? Color.primary : Color.green)
            }
            .frame(minWidth: 64, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(left > 0 ? "Rest, \(Int(left)) seconds left" : "Rest over")
            Button { change(-15) } label: { Text("−15").frame(minWidth: 36, minHeight: 32) }
                .accessibilityLabel("15 seconds less rest this time")
            Button { change(15) } label: { Text("+15").frame(minWidth: 36, minHeight: 32) }
                .accessibilityLabel("15 seconds more rest this time")
            Button("Skip") { model.skipRest() }
                .frame(minHeight: 32)
        }
        .font(.subheadline.weight(.medium))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }

    /// Changes this countdown only; the exercise's own rest is set in its menu.
    private func change(_ by: Int) { model.adjustRest(by: by) }
}

/// One local notification when the rest runs out, replaced whenever the rest changes.
enum RestNotice {
    static let id = "rest-over"

    static func askPermissionIfNeeded() {
        guard !Demo.isRunning else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        }
    }

    /// Notification-centre calls can block for many seconds the first time,
    /// so they run on a serial queue away from the main thread.
    private static let queue = DispatchQueue(label: "rehabit.rest-notice", qos: .utility)

    static func schedule(_ rest: RestTimer?) {
        guard !Demo.isRunning else { return }
        let delay = rest.map { $0.endsAt.timeIntervalSinceNow } ?? 0
        queue.async { place(rest, delay: delay) }
    }

    private static func place(_ rest: RestTimer?, delay: TimeInterval) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard let rest, delay > 1 else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Rest over: \(rest.exercise)"
            content.body = "Time for the next set."
            content.sound = .default
            content.threadIdentifier = "rest"
            center.add(UNNotificationRequest(identifier: id, content: content,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)))
        }
    }
}

/// A hold timed on the phone, on the core's clock (time with the phone locked
/// counts): a large countdown to the target that keeps counting up past it,
/// a tap and a sound at the target, then Stop (saves the seconds and marks
/// the set done) or Cancel (saves nothing).
struct HoldTimerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let set: WorkoutSet
    @State private var reached = false

    var body: some View {
        let run = model.holdRun.flatMap { $0.setID == set.id ? $0 : nil }
        VStack(spacing: 18) {
            Text(set.side == .both ? set.exercise : "\(set.exercise) · \(Format.side(set.side).lowercased())")
                .font(.headline).multilineTextAlignment(.center)
            if let target = set.holdSeconds, target > 0, !set.isDone {
                Text("Target \(Format.number(target)) s").font(.subheadline).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let elapsed = run?.elapsed(at: context.date) ?? 0
                let left = run?.remaining(at: context.date)
                let over = run?.reachedTarget(at: context.date) ?? false
                VStack(spacing: 4) {
                    // Down to the target, then up past it.
                    Text(left.map { $0 > 0 ? String(format: "%.1f", $0) : "+" + String(format: "%.1f", elapsed - (run?.target ?? 0)) }
                         ?? String(format: "%.1f", elapsed))
                        .font(.system(size: 76, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(over ? Color.green : Color.primary)
                    Text(run == nil ? "Ready" : left.map { $0 > 0 ? "seconds to go" : "past the target, \(Format.number(elapsed.rounded())) s held" } ?? "seconds held")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .onChange(of: over) { _, now in
                    if now && !reached {
                        reached = true
                        AudioServicesPlaySystemSound(1057)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .sensoryFeedback(.success, trigger: reached)
            if run == nil {
                Button { reached = false; model.startHold(set) } label: {
                    Text("Start").font(.title2.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    model.stopHold()
                    dismiss()
                } label: {
                    Text("Stop").font(.title2.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Button("Cancel, save nothing", role: .destructive) { model.cancelHold(); dismiss() }
            }
            if run == nil { Button("Close") { dismiss() } }
        }
        .padding(24)
    }
}

/// True when the app runs on made-up demo data (debug builds only), where
/// asking for notification permission would only get in the way.
enum Demo {
    static var isRunning: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("-demo-") }
        #else
        false
        #endif
    }
}
