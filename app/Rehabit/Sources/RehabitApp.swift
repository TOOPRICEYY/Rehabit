import Combine
import Observation
import RehabitCore
import SwiftUI
import UIKit

@main
struct RehabitApp: App {
    @State private var model = RehabitApp.makeModel()

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView().environment(model)
            } else {
                ContentUnavailableView("Storage could not be opened", systemImage: "exclamationmark.triangle",
                                       description: Text("Rehabit could not open its database on this device."))
            }
        }
    }

    /// The database lives in Application Support, which is backed up with the phone.
    private static func makeModel() -> AppModel? {
        #if DEBUG
        if let demo = DemoData.modelIfRequested() { return demo }
        #endif
        let manager = FileManager.default
        guard let folder = try? manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                            appropriateFor: nil, create: true),
              let store = try? Store(path: folder.appendingPathComponent("rehabit.sqlite").path)
        else { return nil }
        return AppModel(store: store)
    }
}

enum AppTab: Hashable { case workouts, checkIns, injuries, load, settings }

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = AppTab.workouts
    @State private var router = NotificationRouter.shared
    private let minute = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $tab) {
            WorkoutsView()
                .tabItem { Label("Workouts", systemImage: "dumbbell") }
                .tag(AppTab.workouts)
            CheckInsView()
                .tabItem { Label("Check-ins", systemImage: "waveform.path.ecg") }
                .badge(model.checkInRound.count)
                .tag(AppTab.checkIns)
            InjuriesView()
                .tabItem { Label("Injuries", systemImage: "bandage") }
                .tag(AppTab.injuries)
            LoadView()
                .tabItem { Label("Load", systemImage: "chart.bar") }
                .tag(AppTab.load)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        // A pain question comes due because time passes, not because data
        // changes, so the lists are worked out again each minute and whenever
        // the app returns to the front.
        .onReceive(minute) { _ in model.refreshClock() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.refreshClock()
                MacSync.shared.checkInbox(model)
            }
        }
        // Reminders follow the questions still to come: answering one, deleting
        // a workout or resolving an injury withdraws its reminders.
        .onChange(of: model.reminderRounds.map(\.id)) { _, _ in
            Reminders.sync(model.reminderRounds)
        }
        .onChange(of: router.opened) { _, _ in tab = .checkIns }
        // Records changed: leave a fresh export for the Mac a few seconds later.
        .onChange(of: model.revision) { _, _ in MacSync.shared.changed(model) }
        .onAppear {
            NotificationRouter.shared.install()
            Reminders.sync(model.reminderRounds)
            MacSync.shared.checkInbox(model)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-demo-inbox") {
                MacSync.shared.offer(DemoData.inbox, model: model)
            }
            #endif
        }
    }
}

enum Format {
    /// 12.5 stays 12.5 and 20.0 becomes 20.
    static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        guard abs(value) < 1e9 else { return String(format: "%.0f", value) }
        if value == value.rounded() { return String(Int(value)) }
        // Up to two decimals, so 12.25 is not shown as 12.3.
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    static func side(_ side: Side) -> String {
        switch side {
        case .left: return "Left"
        case .right: return "Right"
        case .both: return "Both"
        }
    }

    static func moment(_ moment: PainCheckMoment) -> String { moment.label }

    static func summary(_ set: WorkoutSet) -> String {
        var parts: [String] = []
        if set.convention == .bodyweight {
            parts.append("body weight")
        } else if let load = set.loadValue {
            let suffix = set.convention == .perHand ? " per hand" : (set.convention == .bodyweightPlus ? " added" : "")
            parts.append("\(number(load)) \(set.loadUnit.rawValue)\(suffix)")
        }
        if set.kind == .hold {
            parts.append(set.holdSeconds == nil ? "hold" : "\(number(set.holdSeconds)) s hold")
        } else if set.reps != nil {
            parts.append("\(number(set.reps)) reps")
        }
        if set.isWarmup { parts.append("warm-up") }
        if let pain = set.pain { parts.append("pain \(number(pain))") }
        return parts.joined(separator: " · ")
    }

    static let painSteps: [Double] = stride(from: 0.0, through: 10.0, by: 0.5).map { $0 }

    /// "15 × 10", "BW × 12", "20 × 30 s": a set in the fewest characters.
    static func short(_ set: WorkoutSet) -> String {
        let load = set.convention == .bodyweight ? "BW" : (set.loadValue.map { number($0) } ?? "–")
        let count = set.kind == .hold ? "\(set.holdSeconds.map { number($0) } ?? "–") s" : (set.reps.map { number($0) } ?? "–")
        return "\(load) × \(count)"
    }

    /// 0:42, 3:05, 1:02:10.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Green when low, through yellow and orange, to red from 7.
    static func painColor(_ pain: Double?) -> Color {
        guard let pain else { return .secondary }
        switch pain {
        case ..<2.5: return .green
        case ..<5: return Color(red: 0.85, green: 0.65, blue: 0.0)
        case ..<7: return .orange
        default: return .red
        }
    }
}

/// A number field that saves what is typed as it is typed. The system's
/// number-formatting field only hands its value over when the keyboard's
/// Return key is pressed, and the number pad has no Return key, so a typed
/// value could be lost by tapping "Add set" or "Finish".
struct NumberField: View {
    let title: String
    @Binding var value: Double?
    var width: CGFloat = 64
    var decimal = true
    /// What − and + do for this field while it is being typed in; shown above the keys.
    var step: StepAction?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .keyboardType(decimal ? .decimalPad : .numberPad)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .focused($focused)
            .onAppear { text = Format.number(value) }
            .onChange(of: text) { _, typed in
                // Only typing changes the number. Showing a rounded value (45.36 for
                // an exact 45.359237) must never write the rounding back.
                guard focused else { return }
                let clean = Self.parse(typed)
                if clean != value { value = clean }
            }
            .onChange(of: value) { _, changed in
                // A change from elsewhere (a stepper, the linked side) shows even while
                // typing; one that only echoes what was typed leaves the text alone.
                if !focused || Self.parse(text) != changed { text = Format.number(changed) }
            }
            .onChange(of: focused) { _, now in
                if now { StepTarget.shared.current = step }
                else if StepTarget.shared.current?.id == step?.id { StepTarget.shared.current = nil }
            }
    }

    static func parse(_ typed: String) -> Double? {
        let parsed = Double(typed.replacingOccurrences(of: ",", with: "."))
        return parsed.flatMap { $0.isFinite && $0 >= 0 && $0 < 100_000 ? $0 : nil }
    }
}

/// − and + for the number being typed in, shown in the bar above the keys,
/// where a thumb already is.
struct StepAction: Identifiable {
    let id: String
    /// "5 lb", "1 rep", "5 s".
    let label: String
    let minus: () -> Void
    let plus: () -> Void
}

@Observable
final class StepTarget {
    static let shared = StepTarget()
    var current: StepAction?
}

extension View {
    /// The bar above number pads: − and + for the focused number when it has a
    /// step, and Done.
    func keyboardStepBar() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if let step = StepTarget.shared.current {
                    Button { step.minus() } label: { Image(systemName: "minus").frame(width: 44, height: 36) }
                        .accessibilityLabel("Minus \(step.label)")
                    Text(step.label).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    Button { step.plus() } label: { Image(systemName: "plus").frame(width: 44, height: 36) }
                        .accessibilityLabel("Plus \(step.label)")
                }
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
            }
        }
    }

    /// A Done button above number pads, which have no key of their own to close them.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
            }
        }
    }
}

/// A pain slider with no value until it is touched, so an untouched slider
/// cannot be saved as "no pain".
struct PainSlider: View {
    @Binding var pain: Double?

    var body: some View {
        HStack {
            Text("Pain")
            Slider(value: Binding(get: { pain ?? 0 }, set: { pain = $0 }), in: 0...10, step: 0.5)
            Text(pain == nil ? "–" : Format.number(pain)).monospacedDigit().frame(width: 36)
        }
    }
}
