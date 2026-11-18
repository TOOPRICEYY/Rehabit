import Charts
import RehabitCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var bodyweight: Double?
    @State private var unit: WeightUnit = .lb
    @State private var exportURL: URL?
    @State private var spreadsheetURL: URL?
    @State private var spreadsheetError = false
    @State private var bodyweightStatus = ""
    @State private var healthStatus = ""
    @State private var garminConnected = GarminAccount.isConnected
    @State private var garminKey = ""
    @State private var garminStatus = ""
    @State private var garminBusy = false
    @State private var pickingHevy = false
    @State private var pickingSyncFolder = false
    @State private var pickingRecords = false
    @State private var reviewingRecords = false
    @State private var recordsError: String?
    @State private var sync = MacSync.shared
    @State private var hevyStatus = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Unit", selection: Binding(get: { unit }, set: { new in
                        // The weight being typed is the same weight in the new unit, not the same number.
                        bodyweight = bodyweight.map { ($0 * unit.kilograms / new.kilograms * 10).rounded() / 10 }
                        unit = new
                        bodyweightStatus = ""
                        store()
                    })) {
                        ForEach(WeightUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    HStack {
                        Text("Body weight")
                        Spacer()
                        NumberField(title: unit.rawValue, value: $bodyweight, width: 90)
                            .accessibilityLabel("Body weight in \(unit == .lb ? "pounds" : "kilograms")")
                        Button("Save") { saveBodyweight() }
                            .buttonStyle(.borderless)
                            .disabled(bodyweight == nil)
                            .accessibilityLabel("Save body weight for today")
                    }
                    if !bodyweightStatus.isEmpty {
                        Text(bodyweightStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    BodyweightChart(unit: model.profile.unit)
                } header: {
                    Text("You")
                } footer: {
                    Text("Body weight is used for push-ups, pull-ups and other exercises where you are the load. Saving records it for today, so each workout uses the weight you had on its day. Weights read from Apple Health or a scale appear on the chart too.")
                }
                Section {
                    Picker("Rest after a set", selection: Binding(
                        get: { model.profile.defaultRestSeconds },
                        set: { seconds in var p = model.profile; p.defaultRestSeconds = seconds; model.profile = p })) {
                        ForEach(Array(Set([0, 30, 45, 60, 75, 90, 120, 150, 180, 240, 300, model.profile.defaultRestSeconds])).sorted(), id: \.self) { Text(Format.restLength($0)).tag($0) }
                    }
                } header: {
                    Text("Rest timer")
                } footer: {
                    Text("Counts down after a set is marked done. Each exercise can have its own rest, in its menu during a workout.")
                }
                Section {
                    Toggle("Daily check for each injury", isOn: Binding(
                        get: { model.profile.dailyCheckIn },
                        set: { on in var p = model.profile; p.dailyCheckIn = on; model.profile = p }))
                    if model.profile.dailyCheckIn {
                        Picker("Daily check at", selection: Binding(
                            get: { min(11, max(5, model.profile.morningHour)) },
                            set: { hour in var p = model.profile; p.morningHour = hour; model.profile = p })) {
                            ForEach(5...11, id: \.self) { hour in
                                Text(Calendar.current.date(from: DateComponents(hour: hour))
                                    .map { $0.formatted(date: .omitted, time: .shortened) } ?? "\(hour):00").tag(hour)
                            }
                        }
                    }
                } header: {
                    Text("Pain check-ins")
                } footer: {
                    Text("A daily question, asked in the morning, gives each injury a baseline to compare the after-session readings with. It is only saved when you answer it.")
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
                    Text("Reads heart rate variability, resting heart rate, sleep, steps and body weight for the last 60 days. Nothing is written to Health.")
                }
                garminSection
                Section {
                    Button("Import a Hevy export") { pickingHevy = true }
                    if !hevyStatus.isEmpty { Text(hevyStatus).font(.caption) }
                } header: {
                    Text("Hevy")
                } footer: {
                    Text("In Hevy, open Profile, then Settings, then Export & Import Data, and export your workouts. Choose that file here. Importing the same file again adds nothing.")
                }
                Section {
                    if sync.isSetUp {
                        LabeledContent("Folder", value: sync.folderName ?? "Chosen")
                        LabeledContent("Last synced") {
                            if let last = sync.lastSync {
                                Text(last, format: .relative(presentation: .named))
                            } else {
                                Text("Not yet")
                            }
                        }
                        Button(sync.busy ? "Syncing…" : "Sync now") { sync.syncNow(model) }
                            .disabled(sync.busy)
                        Button("Choose another folder") { pickingSyncFolder = true }
                        Button("Stop syncing", role: .destructive) { sync.forget() }
                    } else {
                        Button("Choose the Rehabit folder in iCloud Drive") { pickingSyncFolder = true }
                    }
                    Button("Import a Rehabit file…") { pickingRecords = true }
                    if let error = sync.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if let recordsError {
                        Text(recordsError).font(.caption).foregroundStyle(.red)
                    }
                } header: {
                    Text("Sync with your Mac")
                } footer: {
                    Text("Rehabit leaves a copy of your records in this folder after each workout, pain check-in, injury change or import. Your Mac reads it from iCloud Drive so Claude can use it. Choose iCloud Drive, then the folder named Rehabit.")
                }
                .fileImporter(isPresented: $pickingSyncFolder, allowedContentTypes: [.folder]) { result in
                    if case .success(let url) = result { sync.choose(url, model: model) }
                }
                .sheet(isPresented: $reviewingRecords) {
                    if let waiting = sync.inbox {
                        IncomingRecordsView(records: waiting, onAdd: {
                            sync.takeInbox(model)
                            reviewingRecords = false
                        }, onLater: { reviewingRecords = false })
                    }
                }
                Section {
                    NavigationLink {
                        RecentlyDeletedView()
                    } label: {
                        LabeledContent("Recently deleted") {
                            let count = model.recentlyDeleted.count
                            Text(count == 0 ? "None" : Format.count(count, "workout"))
                        }
                    }
                    Button("Export spreadsheet") {
                        spreadsheetURL = writeSpreadsheet()
                        spreadsheetError = spreadsheetURL == nil
                    }
                    .accessibilityHint("Prepares a CSV file of every finished workout to share or save")
                    if let spreadsheetURL {
                        ShareLink("Share rehabit-export.csv", item: spreadsheetURL)
                    }
                    if spreadsheetError {
                        Text("The spreadsheet could not be written.").font(.caption).foregroundStyle(.red)
                    }
                    Button("Prepare export") { exportURL = writeExport() }
                        .accessibilityHint("Prepares a JSON file with all your records to share or save")
                    if let exportURL {
                        ShareLink("Share export file", item: exportURL)
                    }
                } header: {
                    Text("Your data")
                } footer: {
                    Text("The spreadsheet has one row per set of every finished workout, in the columns of a Hevy export, and opens in Numbers or Excel. The export file is one JSON file with every workout, set, injury and pain reading. Deleted workouts are kept for 30 days.")
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
            .background(Color.clear.fileImporter(isPresented: $pickingRecords, allowedContentTypes: [.json]) { result in
                pickRecords(result)
            })
            .fileImporter(isPresented: $pickingHevy, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                hevyStatus = importHevy(result)
            }
            .keyboardDoneButton()
            .scrollDismissesKeyboard(.interactively)

        }
    }

    /// Body weight as the field shows it: in the chosen unit, to one decimal.
    private func shown(_ profile: Profile) -> Double? {
        profile.bodyweightKg.map { ($0 / profile.unit.kilograms * 10).rounded() / 10 }
    }

    /// Saves the unit. Body weight is not written here: it is saved as a dated
    /// reading (saveBodyweight), which also becomes the profile's weight.
    private func store() {
        guard unit != model.profile.unit else { return }
        // Only the unit changes here; the check-in settings are kept.
        var profile = model.profile
        profile.unit = unit
        model.profile = profile
    }

    /// Records the typed weight as today's reading.
    private func saveBodyweight() {
        guard let bodyweight else { return }
        model.logBodyweight(bodyweight * unit.kilograms)
        if let error = model.lastError {
            bodyweightStatus = error
        } else {
            bodyweightStatus = "Saved \(Format.weight(bodyweight * unit.kilograms, unit)) for today."
            self.bodyweight = shown(model.profile)
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    @ViewBuilder private var garminSection: some View {
        Section {
            if garminConnected {
                Button("Read recovery data from Garmin") {
                    garmin { client in
                        let count = await model.importHealth(from: GarminSource(client: client), days: 90)
                        return count.map { "\($0) daily values read from the last 90 days." }
                    }
                }
                Button("Import strength workouts from Garmin") {
                    garmin { client in
                        guard let summary = await model.importGarminWorkouts(from: client, days: 90) else { return nil }
                        return describe(summary)
                    }
                }
                Button("Remove the Garmin key", role: .destructive) {
                    Keychain.delete(GarminAccount.keyName)
                    garminConnected = false
                    garminStatus = "The key was removed from this phone."
                }
            } else {
                SecureField("Garmin personal API key", text: $garminKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Connect") { connectGarmin() }
                    .disabled(garminKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || garminBusy)
            }
            if garminBusy { ProgressView() }
            if !garminStatus.isEmpty { Text(garminStatus).font(.caption) }
        } header: {
            Text("Garmin")
        } footer: {
            Text(garminConnected
                 ? "Reads overnight HRV, resting heart rate, sleep and steps, and strength sessions as per-exercise totals. Garmin does not record which side a set was done on. Nothing is written to Garmin."
                 : "Paste the personal API key you created in your Garmin Connect account. It is kept in this phone's Keychain and sent only to Garmin.")
        }
        .disabled(garminBusy)
    }

    private func connectGarmin() {
        let key = garminKey.trimmingCharacters(in: .whitespacesAndNewlines)
        garminBusy = true
        garminStatus = "Checking the key with Garmin…"
        Task {
            do {
                try await GarminClient(apiKey: key, transport: URLSessionTransport()).verify()
                if Keychain.write(GarminAccount.keyName, key) {
                    garminConnected = true
                    garminStatus = "Connected."
                } else {
                    garminStatus = "The key works, but it could not be saved to the Keychain."
                }
                garminKey = ""
            } catch {
                garminStatus = String(describing: error)
            }
            garminBusy = false
        }
    }

    /// Runs one Garmin read and shows what it returned, or why it failed.
    private func garmin(_ work: @escaping (GarminClient) async -> String?) {
        guard let client = GarminAccount.client() else {
            garminConnected = false
            return
        }
        garminBusy = true
        garminStatus = "Reading from Garmin…"
        Task {
            let text = await work(client)
            garminStatus = text ?? model.lastError ?? "Garmin could not be read."
            garminBusy = false
        }
    }

    private func describe(_ summary: ImportSummary) -> String {
        var text = "\(summary.workoutsAdded) workouts and \(summary.setsAdded) sets added."
        if summary.workoutsSkipped > 0 { text += " \(summary.workoutsSkipped) were already here." }
        if summary.sidesInferred > 0 { text += " \(summary.sidesInferred) sets were given a side from a note or an injury." }
        if !summary.unmapped.isEmpty {
            text += " Not counted toward tissue load because the exercise is not recognised: " + summary.unmapped.joined(separator: ", ") + "."
        }
        return text
    }

    /// A Rehabit records file picked by hand: read it, then show what it would add.
    private func pickRecords(_ result: Result<URL, Error>) {
        recordsError = nil
        guard case .success(let url) = result else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            recordsError = "That file could not be read."
            return
        }
        do {
            let records = try model.incoming(data)
            if records.isEmpty {
                recordsError = "Everything in that file is already on this phone."
            } else if sync.offer(data, model: model) {
                reviewingRecords = true
            }
        } catch {
            recordsError = "That is not a Rehabit records file: \(error)"
        }
    }

    private func importHevy(_ result: Result<URL, Error>) -> String {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let text = try String(contentsOf: url, encoding: .utf8)
            let summary = model.importWorkouts(try HevyCSV.parse(text), source: HevyCSV.source)
            return model.lastError ?? describe(summary)
        } catch {
            return String(describing: error)
        }
    }

    private func writeSpreadsheet() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rehabit-export.csv")
        return (try? Data(model.exportCSV().utf8).write(to: url, options: .atomic)) == nil ? nil : url
    }

    private func writeExport() -> URL? {
        guard let data = model.exportJSON() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rehabit-export.json")
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }
}

// MARK: - Body weight chart

/// Body weight over the last 90 days in the person's unit: what was typed in
/// here and what Apple Health or a scale reported, one value a day.
private struct BodyweightChart: View {
    @Environment(AppModel.self) private var model
    let unit: WeightUnit

    var body: some View {
        let today = Day(Date())
        let points = model.bodyweightHistory.filter { $0.day >= today.adding(-90) && $0.day <= today }
        if let first = points.first, let last = points.last {
            // A fixed range around the readings: with one reading, or a flat run,
            // an automatic scale has no height and draws no labels.
            let values = points.map { $0.kg / unit.kilograms }
            let low = values.min() ?? 0, high = values.max() ?? 0
            let pad = max(unit == .lb ? 4 : 2, (high - low) * 0.2)
            VStack(alignment: .leading, spacing: 6) {
                Text("Last 90 days").font(.subheadline.weight(.semibold))
                Chart {
                    ForEach(points, id: \.day) { point in
                        LineMark(x: .value("Day", Format.date(point.day), unit: .day),
                                 y: .value("Body weight", point.kg / unit.kilograms))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Day", Format.date(point.day), unit: .day),
                                  y: .value("Body weight", point.kg / unit.kilograms))
                            .symbolSize(points.count > 30 ? 12 : 30)
                    }
                }
                .chartYScale(domain: (low - pad).rounded(.down)...(high + pad).rounded(.up))
                .chartXScale(domain: Format.date(today.adding(-90))...Format.date(today.adding(1)))
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text("\(v.formatted(.number.precision(.fractionLength(0)))) \(unit.rawValue)") }
                        }
                    }
                }
                .frame(height: 140)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Body weight chart, last 90 days")
                .accessibilityValue(points.count == 1
                    ? "One reading: \(Format.weight(last.kg, unit)) on \(last.day.readable)"
                    : "\(points.count) readings, from \(Format.weight(first.kg, unit)) on \(first.day.readable) to \(Format.weight(last.kg, unit)) on \(last.day.readable)")
                Text("Latest \(Format.weight(last.kg, unit)) on \(last.day.readable)")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
        } else {
            Text("No body weight saved in the last 90 days. Weights you save appear here as a chart.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Recently deleted

/// Workouts deleted on this phone in the last 30 days, each with a way back.
private struct RecentlyDeletedView: View {
    @Environment(AppModel.self) private var model
    @State private var result = ""

    var body: some View {
        let deleted = model.recentlyDeleted
        List {
            if !result.isEmpty {
                Section {
                    Text(result).font(.callout)
                }
            }
            Section {
                if deleted.isEmpty {
                    Text("Nothing deleted").foregroundStyle(.secondary)
                }
                ForEach(deleted) { item in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.workout.title)
                            Text("\(item.workout.start.formatted(date: .abbreviated, time: .shortened)) · \(Format.count(item.sets, "set"))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Deleted \(item.deletedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer()
                        Button("Restore") { restore(item) }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Restore \(item.workout.title)")
                    }
                }
            } footer: {
                Text("Deleted workouts are kept for 30 days. A restored workout comes back with its sets, finished.")
            }
        }
        .navigationTitle("Recently deleted")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func restore(_ item: DeletedWorkout) {
        if model.restoreWorkout(id: item.id) {
            result = "\(item.workout.title) is back in your workouts."
        } else {
            result = model.lastError.map { "\(item.workout.title) could not be restored: \($0)" }
                ?? "\(item.workout.title) could not be restored. Its copy may have passed 30 days."
        }
    }
}
