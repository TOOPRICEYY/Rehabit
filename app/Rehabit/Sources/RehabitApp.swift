import RehabitCore
import SwiftUI

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

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            WorkoutsView()
                .tabItem { Label("Workouts", systemImage: "dumbbell") }
            CheckInsView()
                .tabItem { Label("Check-ins", systemImage: "waveform.path.ecg") }
                .badge(model.dueChecks.count)
            InjuriesView()
                .tabItem { Label("Injuries", systemImage: "bandage") }
            LoadView()
                .tabItem { Label("Load", systemImage: "chart.bar") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

enum Format {
    /// 12.5 stays 12.5 and 20.0 becomes 20.
    static func number(_ value: Double?) -> String {
        guard let value else { return "" }
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
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
        if let load = set.loadValue {
            let suffix = set.convention == .perHand ? " per hand" : (set.convention == .bodyweightPlus ? " added" : "")
            parts.append("\(number(load)) \(set.loadUnit.rawValue)\(suffix)")
        } else if set.convention == .bodyweight {
            parts.append("body weight")
        }
        if set.kind == .hold {
            parts.append("\(number(set.holdSeconds)) s hold")
        } else {
            parts.append("\(number(set.reps)) reps")
        }
        if let pain = set.pain { parts.append("pain \(number(pain))") }
        return parts.joined(separator: " · ")
    }

    static let painSteps: [Double] = stride(from: 0.0, through: 10.0, by: 0.5).map { $0 }
}
