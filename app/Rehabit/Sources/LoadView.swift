import RehabitCore
import SwiftUI

enum LoadLayout: String, CaseIterable { case body, list }

/// The Load tab: the body map by default, or the per-tissue bars.
struct LoadView: View {
    @AppStorage("loadLayout") private var layout = LoadLayout.body

    var body: some View {
        NavigationStack {
            Group {
                switch layout {
                case .body: BodyHeatmapView()
                case .list: LoadListView()
                }
            }
            .navigationTitle("Load")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $layout) {
                        Text("Body").tag(LoadLayout.body)
                        Text("List").tag(LoadLayout.list)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Each tissue and side: the last 7 days against its own previous four weeks.
struct LoadListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
            List {
                let weeks = model.tissueWeeks()
                if weeks.isEmpty {
                    Text("Log a workout to see load by tissue.").foregroundStyle(.secondary)
                }
                ForEach(weeks) { week in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(week.tissue.name) · \(Format.side(week.side))")
                            Spacer()
                            Text(ratioText(week)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        // The bar is this week; the tick is a usual week.
                        GeometryReader { geometry in
                            let scale = max(week.week, week.usualWeek, 1) * 1.1
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary)
                                Capsule().fill(.tint)
                                    .frame(width: geometry.size.width * week.week / scale)
                                if week.usualWeek > 0 {
                                    Rectangle().fill(.primary)
                                        .frame(width: 2)
                                        .offset(x: geometry.size.width * week.usualWeek / scale)
                                }
                            }
                        }
                        .frame(height: 8)
                        Text("\(Int(week.week.rounded())) effective reps this week, usually \(Int(week.usualWeek.rounded()))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                Section {
                } footer: {
                    Text("An effective rep is one rep at your usual weight for that exercise. Heavier reps count for more, by the square of the load ratio. These are descriptions of load, not advice; progression is your physical therapist's call.")
                }
            }
    }

    private func ratioText(_ week: TissueWeek) -> String {
        guard let ratio = week.ratio else { return "new" }
        return String(format: "%.1f× usual", ratio)
    }
}
