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
                .badge(model.dueChecks.count)
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
            if phase == .active { model.refreshClock() }
        }
        // Reminders follow the questions still to come: answering one, deleting
        // a workout or resolving an injury withdraws its reminders.
        .onChange(of: model.upcomingChecks.map(\.id)) { _, _ in
            Reminders.sync(model.upcomingChecks, injuries: model.injuries)
        }
        .onChange(of: router.opened) { _, _ in tab = .checkIns }
        .onAppear {
            NotificationRouter.shared.install()
            Reminders.sync(model.upcomingChecks, injuries: model.injuries)
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

    static func moment(_ moment: PainCheckMoment) -> String {
        switch moment {
        case .afterSession: return "Right after the session"
        case .evening: return "That evening"
        case .nextMorning: return "The next morning"
        case .hours24: return "24 hours after"
        case .hours48: return "48 hours after"
        case .baseline: return "Baseline"
        }
    }

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
                let parsed = Double(typed.replacingOccurrences(of: ",", with: "."))
                let clean = parsed.flatMap { $0.isFinite && $0 >= 0 && $0 < 100_000 ? $0 : nil }
                if clean != value { value = clean }
            }
            .onChange(of: value) { _, changed in
                if !focused { text = Format.number(changed) }
            }
    }
}

extension View {
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
