import RehabitCore
import SwiftUI

/// A card at the top of the Injuries tab when records prepared on the Mac are
/// waiting. Nothing is stored until "Add all" in the review sheet.
struct IncomingCard: View {
    let records: IncomingRecords
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(IncomingRecordsView.headline(records)).font(.headline).foregroundStyle(.primary)
                    Text("Prepared on your Mac. Review them before they are added.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
        .accessibilityHint("Opens the list to review")
    }
}

/// Everything a file would add or change, for a yes or a not now.
struct IncomingRecordsView: View {
    @Environment(AppModel.self) private var model
    let records: IncomingRecords
    let onAdd: () -> Void
    let onLater: () -> Void

    static func headline(_ r: IncomingRecords) -> String {
        if !r.injuries.isEmpty && r.workouts.isEmpty && r.sets == 0 && r.painChecks == 0 {
            return r.injuries.count == 1 ? "1 injury is waiting to be added"
                                         : "\(r.injuries.count) injuries are waiting to be added"
        }
        return r.count == 1 ? "1 record is waiting to be added" : "\(r.count) records are waiting to be added"
    }

    var body: some View {
        NavigationStack {
            List {
                if !records.injuries.isEmpty {
                    Section("Injuries") {
                        ForEach(records.injuries) { injury in
                            injuryRow(injury)
                        }
                    }
                }
                if !records.workouts.isEmpty || records.sets > 0 || records.painChecks > 0 {
                    Section("Also") {
                        if !records.workouts.isEmpty { Text("\(records.workouts.count) workouts") }
                        if records.sets > 0 { Text("\(records.sets) sets") }
                        if records.painChecks > 0 { Text("\(records.painChecks) pain check-ins") }
                    }
                }
                Section {
                } footer: {
                    Text("Adding stores these on this phone. Anything with the same record already here is updated to this version; nothing is deleted. \(records.unreadable > 0 ? "\(records.unreadable) records in the file could not be read by this version and are left out." : "")")
                }
            }
            .navigationTitle(Self.headline(records))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("Not now", action: onLater)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    Button(action: onAdd) {
                        Text("Add all").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }

    private func injuryRow(_ injury: Injury) -> some View {
        let existing = model.injuries.contains { $0.id == injury.id }
        let tissues = injury.tissues.map { model.library.tissue($0)?.name ?? $0 }.joined(separator: ", ")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(injury.label).font(.headline)
                Spacer()
                if existing {
                    Text("update").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }
            Text("\(injury.side == .both ? "Both sides" : "\(Format.side(injury.side)) side") · since \(Self.onset(injury))")
                .font(.subheadline)
            if !tissues.isEmpty {
                Label(tissues, systemImage: "figure.strengthtraining.traditional").font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !injury.mechanism.isEmpty {
                Text("How it began: \(injury.mechanism)").font(.subheadline).foregroundStyle(.secondary)
            }
            if !injury.notes.isEmpty {
                Text(injury.notes).font(.caption).foregroundStyle(.secondary)
            }
            if !injury.isActive, let resolved = injury.resolvedOn {
                Text("Resolved \(resolved.description)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// The start date as precisely as it is known: a day, a week or a month.
    static func onset(_ injury: Injury) -> String {
        let parts = injury.onset.description.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return injury.onset.description }
        switch injury.onsetPrecision {
        case .day: return date.formatted(.dateTime.day().month(.abbreviated).year())
        case .week: return "the week of \(date.formatted(.dateTime.day().month(.abbreviated).year()))"
        case .month: return date.formatted(.dateTime.month(.wide).year())
        }
    }
}
