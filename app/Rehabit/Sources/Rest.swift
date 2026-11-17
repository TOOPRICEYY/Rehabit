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
                .accessibilityLabel("15 seconds less rest for \(rest.exercise)")
            Button { change(15) } label: { Text("+15").frame(minWidth: 36, minHeight: 32) }
                .accessibilityLabel("15 seconds more rest for \(rest.exercise)")
            Button("Skip") { model.skipRest() }
                .frame(minHeight: 32)
        }
        .font(.subheadline.weight(.medium))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }

    /// Changes this exercise's own rest, which also moves the countdown running now.
    private func change(_ by: Int) {
        let next = max(0, model.restSeconds(for: rest.exercise) + by)
        model.setRest(next, for: rest.exercise)
    }
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

    static func schedule(_ rest: RestTimer?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard let rest, !Demo.isRunning else { return }
        let delay = rest.endsAt.timeIntervalSinceNow
        guard delay > 1 else { return }
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

/// A hold timed on the phone: counts up in large type, taps at the target,
/// and Stop writes the seconds held and marks the set done.
struct HoldTimerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let set: WorkoutSet
    @State private var started: Date?
    @State private var reachedTarget = false

    var body: some View {
        VStack(spacing: 20) {
            Text(set.side == .both ? set.exercise : "\(set.exercise) · \(Format.side(set.side).lowercased())")
                .font(.headline).multilineTextAlignment(.center)
            if let target = set.holdSeconds, target > 0 {
                Text("Target \(Format.number(target)) s").font(.subheadline).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let held = started.map { context.date.timeIntervalSince($0) } ?? 0
                Text(String(format: "%.1f", held))
                    .font(.system(size: 72, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(reachedTarget ? Color.green : Color.primary)
                    .onChange(of: Int(held)) { _, whole in
                        if let target = set.holdSeconds, target > 0, Double(whole) >= target, !reachedTarget {
                            reachedTarget = true
                        }
                    }
                    .accessibilityLabel("\(Int(held)) seconds held")
            }
            .sensoryFeedback(.success, trigger: reachedTarget)
            if started == nil {
                Button { started = Date() } label: { Text("Start").font(.title2.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 56) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button {
                    if let started { model.finishHold(set, seconds: Date().timeIntervalSince(started)) }
                    dismiss()
                } label: { Text("Stop").font(.title2.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 56) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            Button("Cancel", role: .cancel) { dismiss() }
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
