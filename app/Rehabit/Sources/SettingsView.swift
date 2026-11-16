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
                    Picker("Unit", selection: Binding(get: { unit }, set: { new in
                        // The weight is the same weight in the new unit, not the same number.
                        bodyweight = bodyweight.map { ($0 * unit.kilograms / new.kilograms * 10).rounded() / 10 }
                        unit = new
                        store()
                    })) {
                        ForEach(WeightUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        Text("Body weight")
                        Spacer()
                        NumberField(title: unit.rawValue, value: $bodyweight, width: 90)
                    }
                } footer: {
                    Text("Body weight is used for push-ups, pull-ups and other exercises where you are the load.")
                }
                Section {
                    Button("Read from Apple Health") {
                        Task {
                            healthStatus = "Reading…"
                            let count = await model.importHealth(from: HealthKitSource())
                            if let error = model.lastError {
                                healthStatus = error
                            } else if let count, count > 0 {
                                healthStatus = "\(count) daily values read from the last 60 days."
                            } else if count == 0 {
                                // Apple does not tell an app whether reading was refused; refused and empty look the same.
                                healthStatus = "Nothing was returned. If you expected data, allow Rehabit to read it in the Health app under Sharing, then Apps."
                            } else {
                                healthStatus = "Health data is not available on this device."
                            }
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
                if model.unreadableCount > 0 {
                    Section {
                        Text("\(model.unreadableCount) records were written by a newer version of Rehabit. They are kept and included in exports, but this version cannot show them.")
                            .font(.footnote)
                    }
                }
                Section {
                } footer: {
                    Text("Rehabit describes training load and pain. It is not medical advice.")
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                unit = model.profile.unit
                bodyweight = shown(model.profile)
            }
            .keyboardDoneButton()
            .scrollDismissesKeyboard(.interactively)

            .onChange(of: bodyweight) { _, _ in store() }
        }
    }

    /// Body weight as the field shows it: in the chosen unit, to one decimal.
    private func shown(_ profile: Profile) -> Double? {
        profile.bodyweightKg.map { ($0 / profile.unit.kilograms * 10).rounded() / 10 }
    }

    private func store() {
        // Opening this screen must not rewrite the stored weight with a rounded copy of itself.
        if unit == model.profile.unit && bodyweight == shown(model.profile) { return }
        model.profile = Profile(bodyweightKg: bodyweight.map { $0 * unit.kilograms }, unit: unit)
    }

    private func writeExport() -> URL? {
        guard let data = model.exportJSON() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rehabit-export.json")
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }
}
