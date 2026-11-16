import RehabitCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var bodyweight: Double?
    @State private var unit: WeightUnit = .lb
    @State private var exportURL: URL?
    @State private var healthStatus = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Unit", selection: $unit) {
                        ForEach(WeightUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        Text("Body weight")
                        Spacer()
                        TextField(unit.rawValue, value: $bodyweight, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                    }
                } footer: {
                    Text("Body weight is used for push-ups, pull-ups and other exercises where you are the load.")
                }
                Section {
                    Button("Read from Apple Health") {
                        Task {
                            healthStatus = "Reading…"
                            await model.importHealth(from: HealthKitSource())
                            let nights = model.dailyMetrics(MetricName.sleepMinutes).count
                            let steps = model.dailyMetrics(MetricName.steps).count
                            healthStatus = model.lastError ?? "\(nights) nights of sleep and \(steps) days of steps stored."
                        }
                    }
                    if !healthStatus.isEmpty { Text(healthStatus).font(.caption) }
                } header: {
                    Text("Recovery data")
                } footer: {
                    Text("Reads heart rate variability, resting heart rate, sleep and steps for the last 60 days. Nothing is written to Health.")
                }
                Section {
                    if let exportURL {
                        ShareLink("Share export file", item: exportURL)
                    }
                    Button("Prepare export") { exportURL = writeExport() }
                } header: {
                    Text("Your data")
                } footer: {
                    Text("One JSON file with every workout, set, injury and pain reading.")
                }
                Section {
                } footer: {
                    Text("Rehabit describes training load and pain. It is not medical advice.")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                unit = model.profile.unit
                bodyweight = model.profile.bodyweightKg.map { ($0 / unit.kilograms * 10).rounded() / 10 }
            }
            .onChange(of: unit) { _, _ in store() }
            .onChange(of: bodyweight) { _, _ in store() }
        }
    }

    private func store() {
        model.profile = Profile(bodyweightKg: bodyweight.map { $0 * unit.kilograms }, unit: unit)
    }

    private func writeExport() -> URL? {
        guard let data = model.exportJSON() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rehabit-export.json")
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }
}
