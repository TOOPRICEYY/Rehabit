import RehabitCore
import SwiftUI

/// A session with no sets that no watch recorded, such as an evening of
/// pickleball: what it was, when, and how long. With Apple Health connected,
/// the steps and heart rate inside that window are filled in from it.
struct LogActivitySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kind = ""
    @State private var name = ""
    @State private var start = Date().addingTimeInterval(-3600)
    @State private var minutes: Double? = 60
    @State private var averageHR: Double?
    @State private var steps: Double?
    @State private var filled = ""

    private var title: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? (model.activityKinds.first { $0.id == kind }?.name ?? "Activity") : typed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        Text("Choose").tag("")
                        ForEach(model.activityKinds, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .accessibilityIdentifier("log-activity-kind")
                    TextField("Name (optional)", text: $name)
                } footer: {
                    Text("The kind sets which tissues it loads and how much.")
                }
                Section {
                    DatePicker("Started", selection: $start, in: ...Date())
                    HStack {
                        Text("Minutes")
                        Spacer()
                        NumberField(title: "min", value: $minutes, width: 70, decimal: false)
                            .accessibilityLabel("Minutes")
                    }
                    HStack {
                        Text("Average heart rate")
                        Spacer()
                        NumberField(title: "bpm", value: $averageHR, width: 70, decimal: false)
                            .accessibilityLabel("Average heart rate")
                    }
                    HStack {
                        Text("Steps")
                        Spacer()
                        NumberField(title: "steps", value: $steps, width: 90, decimal: false)
                            .accessibilityLabel("Steps")
                    }
                } footer: {
                    Text(filled.isEmpty ? "Heart rate and steps are optional. Without heart rate the effort is taken as moderate." : filled)
                }
            }
            .keyboardDoneButton()
            .navigationTitle("Log an activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(kind.isEmpty || (minutes ?? 0) <= 0)
                }
            }
            .task(id: "\(start.timeIntervalSince1970)-\(minutes ?? 0)") { await fill() }
        }
    }

    /// Steps and heart rate from Apple Health inside the window, when connected
    /// and nothing was typed by hand.
    private func fill() async {
        guard AutoRefresh.healthConnected, !Demo.isRunning, let minutes, minutes > 0 else { return }
        let source = HealthKitSource()
        guard !(await source.needsPermission(for: HealthKitSource.activityTypes)) else { return }
        let window = await source.window(from: start, to: start.addingTimeInterval(minutes * 60))
        if averageHR == nil, let hr = window.averageHR { averageHR = hr.rounded() }
        if steps == nil, let s = window.steps { steps = s.rounded() }
        if window.averageHR != nil || window.steps != nil { filled = "Filled in from Apple Health for that time. Change them if they look wrong." }
    }

    private func save() {
        let length = (minutes ?? 0) * 60
        var summary = ActivitySummary(type: kind, averageHeartRate: averageHR, steps: steps)
        summary.countsAs = kind
        model.importWorkouts([ImportedWorkout(sourceID: UUID().uuidString, title: title, start: start,
                                              end: start.addingTimeInterval(length), activity: summary)],
                             source: "manual", inferSide: false)
        dismiss()
    }
}
