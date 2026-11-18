import RehabitCore
import SwiftUI

/// A tissue on one side, as chosen on the body map.
struct TissueSide: Identifiable, Hashable {
    let tissue: String
    let side: Side
    var id: String { tissue + "|" + side.rawValue }
}

/// Front and back figures, each muscle and tendon coloured by its load.
/// Descriptions of load, not advice.
struct BodyHeatmapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("heatReading") private var reading = HeatReading.versusUsual
    @State private var weeksAgo = 0
    @State private var selected: TissueSide?
    /// Set once the person picks a reading here, so a short history does not override it.
    @State private var pickedReading = false

    var body: some View {
        let weeks = model.tissueWeeks(weeksAgo: weeksAgo)
        let maxWeek = weeks.map(\.week).max() ?? 0
        let injured = model.injuredTissueSides
        let compared = model.hasUsualWeek
        // With no usual week yet, "This week" is shown first; the person can still switch.
        let reading = compared || pickedReading ? self.reading : .thisWeek
        ScrollView {
            VStack(spacing: 14) {
                Picker("Colour shows", selection: Binding(get: { reading },
                                                          set: { self.reading = $0; pickedReading = true })) {
                    Text("Versus usual").tag(HeatReading.versusUsual)
                    Text("This week").tag(HeatReading.thisWeek)
                }
                .pickerStyle(.segmented)

                if !compared {
                    Text("Not enough history yet to compare with a usual week")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                weekStepper

                let figures = ForEach(BodyView.allCases, id: \.self) { view in
                    FigureView(view: view, weeks: weeks, reading: reading, maxWeek: maxWeek, injured: injured,
                               compared: compared) {
                        selected = $0
                    }
                }
                Group {
                    if typeSize.isAccessibilitySize {
                        VStack(spacing: 20) { figures }
                    } else {
                        HStack(alignment: .top, spacing: 12) { figures }
                    }
                }
                .overlay {
                    if weeks.allSatisfy({ $0.week == 0 }) {
                        Text(weeksAgo == 0 && weeks.isEmpty ? "Log a workout to see load on the body."
                                                            : "No load logged this week.")
                            .font(.subheadline.weight(.medium))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                    }
                }

                HeatLegend(reading: reading, maxWeek: maxWeek, compared: compared)

                Text(reading == .versusUsual && !compared
                     ? "Each side is this week's load in effective reps. Versus usual needs a usual week, the average of the four weeks before. Tap a muscle for its numbers. A description of load, not advice."
                     : reading == .versusUsual
                     ? "Each side is this week's load against its own usual week, the average of the four weeks before. Tap a muscle for its numbers. A description of load, not advice."
                     : "Each side is this week's load in effective reps, against the most-loaded tissue. Tap a muscle for its numbers. A description of load, not advice.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .sheet(item: $selected) { choice in
            TissueDetailSheet(choice: choice, weeksAgo: weeksAgo, compared: compared)
                .presentationDetents([.medium, .large])
        }
    }

    private var weekStepper: some View {
        HStack {
            Button {
                weeksAgo = min(4, weeksAgo + 1)
            } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 30)
            }
            .disabled(weeksAgo >= 4)
            .accessibilityLabel("Earlier week")
            Spacer()
            VStack(spacing: 0) {
                Text(weeksAgo == 0 ? "Last 7 days" : weeksAgo == 1 ? "The week before" : "\(weeksAgo) weeks back")
                    .font(.subheadline.weight(.semibold))
                Text(weekRange).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button {
                weeksAgo = max(0, weeksAgo - 1)
            } label: {
                Image(systemName: "chevron.right").frame(width: 36, height: 30)
            }
            .disabled(weeksAgo == 0)
            .accessibilityLabel("Later week")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var weekRange: String {
        let end = Calendar.current.date(byAdding: .day, value: -7 * weeksAgo, to: Date()) ?? Date()
        let start = Calendar.current.date(byAdding: .day, value: -6, to: end) ?? end
        return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

// MARK: - A figure

struct FigureView: View {
    @Environment(AppModel.self) private var model
    let view: BodyView
    let weeks: [TissueWeek]
    let reading: HeatReading
    let maxWeek: Double
    let injured: [String: Set<Side>]
    /// False with no usual week yet: loaded regions are not marked "new".
    var compared = true
    let onSelect: (TissueSide) -> Void

    var body: some View {
        VStack(spacing: 4) {
            Text(view == .front ? "Front" : "Back")
                .font(.caption.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                let scale = min(geometry.size.width / BodyMap.size.width, geometry.size.height / BodyMap.size.height)
                let origin = CGPoint(x: (geometry.size.width - BodyMap.size.width * scale) / 2, y: 0)
                ZStack(alignment: .topLeading) {
                    silhouette(scale: scale, origin: origin)
                    ForEach(Array(BodyMap.regions(view).enumerated()), id: \.offset) { _, region in
                        regionView(region, viewerLeft: true, scale: scale, origin: origin)
                        regionView(region, viewerLeft: false, scale: scale, origin: origin)
                    }
                    sideMarks(scale: scale, origin: origin)
                }
            }
            .aspectRatio(BodyMap.size.width / BodyMap.size.height, contentMode: .fit)
        }
        .frame(maxWidth: 260)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(view == .front ? "Front of the body" : "Back of the body")
    }

    private func silhouette(scale: CGFloat, origin: CGPoint) -> some View {
        let shapes = BodyMap.centre + BodyMap.half + BodyMap.half.map(\.mirrored)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(shapes.enumerated()), id: \.offset) { _, shape in
                EllipsePath(shape: shape, scale: scale, origin: origin)
                    .fill(Color(.tertiarySystemFill))
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func regionView(_ region: BodyRegion, viewerLeft: Bool, scale: CGFloat, origin: CGPoint) -> some View {
        let side = view.side(onViewerLeft: viewerLeft)
        let shape = EllipsePath(shape: viewerLeft ? region.shape : region.shape.mirrored, scale: scale, origin: origin)
        let week = model.tissueWeek(region.tissue, side: side, in: weeks)
        let level = HeatLevel(week, reading: reading, maxWeek: maxWeek)
        let hurt = injured[region.tissue]?.contains(side) == true
        ZStack {
            switch level {
            case .empty:
                shape.fill(Color(.systemBackground).opacity(0.6))
            case .new where !compared:
                shape.fill(HeatColor.loadedFill)
            case .new:
                shape.fill(HeatColor.newFill)
                Stripes().stroke(HeatColor.newStripe, lineWidth: 1.2).clipShape(shape)
            case .value(let v):
                shape.fill(HeatColor.color(v, reading: reading))
            }
            shape.stroke(hurt ? Color.orange : Color.secondary.opacity(region.isTendon ? 0.9 : 0.45),
                         style: StrokeStyle(lineWidth: hurt ? 2.2 : (region.isTendon ? 1.2 : 0.8),
                                            dash: hurt ? [3, 2] : []))
        }
        .contentShape(shape)
        .onTapGesture { onSelect(TissueSide(tissue: region.tissue, side: side)) }
        .accessibilityElement()
        .accessibilityLabel(label(region.tissue, side: side, injured: hurt))
        .accessibilityValue(value(week))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect(TissueSide(tissue: region.tissue, side: side)) }
    }

    /// L and R printed on each figure, on the half that side is drawn on.
    private func sideMarks(scale: CGFloat, origin: CGPoint) -> some View {
        ForEach([true, false], id: \.self) { viewerLeft in
            Text(view.side(onViewerLeft: viewerLeft) == .left ? "L" : "R")
                .font(.caption2.weight(.heavy))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(.secondary)
                .position(x: origin.x + (viewerLeft ? 14 : BodyMap.size.width - 14) * scale, y: 30 * scale)
                .accessibilityHidden(true)
        }
    }

    private func label(_ tissue: String, side: Side, injured: Bool) -> String {
        let name = model.library.tissue(tissue)?.name.lowercased() ?? tissue
        return "\(Format.side(side)) \(name)\(injured ? ", injured" : "")"
    }

    private func value(_ week: TissueWeek?) -> String {
        guard let week, week.week > 0 else { return "no load this week" }
        let reps = "\(Int(week.week.rounded())) effective reps"
        guard let ratio = week.ratio else { return compared ? "new this week, \(reps)" : reps }
        return "\(Format.ratio(ratio)) usual, \(reps)"
    }
}

/// An ellipse from the body map, in view points.
struct EllipsePath: Shape {
    let shape: BodyShape
    let scale: CGFloat
    let origin: CGPoint

    func path(in _: CGRect) -> Path {
        let w = shape.width * scale, h = shape.height * scale
        let ellipse = Path(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        let transform = CGAffineTransform(rotationAngle: shape.rotation * .pi / 180)
            .concatenating(CGAffineTransform(translationX: origin.x + shape.x * scale, y: origin.y + shape.y * scale))
        return ellipse.applying(transform)
    }
}

/// Diagonal hatching, the mark for a tissue with no usual week to compare with.
struct Stripes: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let gap: CGFloat = 4.5
        var x = rect.minX - rect.height
        while x < rect.maxX {
            p.move(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += gap
        }
        return p
    }
}

// MARK: - Colour

enum HeatColor {
    static let low = (r: 0.16, g: 0.45, b: 0.86)       // blue: under usual
    static let mid = (r: 0.80, g: 0.80, b: 0.82)       // neutral grey: usual
    static let high = (r: 0.96, g: 0.52, b: 0.10)      // orange: over usual
    static let newFill = Color.purple.opacity(0.18)
    static let newStripe = Color.purple.opacity(0.7)
    /// Loaded, with no usual week to compare with yet.
    static let loadedFill = Color.secondary.opacity(0.45)

    static func color(_ value: Double, reading: HeatReading) -> Color {
        switch reading {
        case .thisWeek:
            // One hue, faint to strong. Even the lightest load stays visible.
            return Color(red: 0.0, green: 0.6, blue: 0.68).opacity(0.3 + 0.7 * max(0, min(1, value)))
        case .versusUsual:
            let t = max(-1, min(1, value))
            let to = t < 0 ? low : high, k = abs(t)
            return Color(red: mid.r + (to.r - mid.r) * k, green: mid.g + (to.g - mid.g) * k, blue: mid.b + (to.b - mid.b) * k)
        }
    }
}

extension Format {
    /// 1.4×, 0.5×, 12×.
    static func ratio(_ ratio: Double) -> String {
        ratio >= 10 ? "\(Int(ratio.rounded()))×" : String(format: "%.1f×", ratio)
    }
}

/// The scale with numbers on it, and the marks for no load, new and injured.
struct HeatLegend: View {
    let reading: HeatReading
    let maxWeek: Double
    var compared = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A scale up to 0 reps says nothing; with no load, only the marks below are shown.
            if (reading == .thisWeek && maxWeek > 0) || (reading == .versusUsual && compared) { scale }
            HStack(spacing: 14) {
                swatch("no load") {
                    Capsule().fill(Color(.systemBackground)).overlay(Capsule().stroke(Color.secondary.opacity(0.6), lineWidth: 1))
                }
                if reading == .versusUsual {
                    if compared {
                        swatch("new") {
                            ZStack {
                                Capsule().fill(HeatColor.newFill)
                                Stripes().stroke(HeatColor.newStripe, lineWidth: 1.2).clipShape(Capsule())
                            }
                        }
                    } else {
                        swatch("loaded") { Capsule().fill(HeatColor.loadedFill) }
                    }
                }
                swatch("injured") {
                    Capsule().stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var scale: some View {
            GeometryReader { geometry in
                let stops = (0...20).map { i -> Gradient.Stop in
                    let t = Double(i) / 20
                    let v = reading == .versusUsual ? t * 2 - 1 : t
                    return Gradient.Stop(color: HeatColor.color(v, reading: reading), location: t)
                }
                VStack(alignment: .leading, spacing: 3) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 12)
                    ZStack(alignment: .topLeading) {
                        ForEach(ticks, id: \.label) { tick in
                            Text(tick.label)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .position(x: max(14, min(geometry.size.width - 18, geometry.size.width * tick.at)), y: 7)
                        }
                    }
                    .frame(height: 14)
                }
            }
            .frame(height: 30)
            .accessibilityElement()
            .accessibilityLabel(reading == .versusUsual
                                ? "Scale from half a usual week, blue, through usual, grey, to double or more, orange"
                                : "Scale from light to strong, up to \(Int(maxWeek.rounded())) effective reps")
    }

    private var ticks: [(label: String, at: Double)] {
        switch reading {
        case .versusUsual:
            return [("0.5×", 0), ("1×", 0.5), ("1.5×", 0.5 + log2(1.5) / 2), ("2×+", 1)]
        case .thisWeek:
            return [("light", 0.06), ("\(Int(maxWeek.rounded())) reps", 1)]
        }
    }

    private func swatch<S: View>(_ label: String, @ViewBuilder _ shape: () -> S) -> some View {
        HStack(spacing: 5) {
            shape().frame(width: 22, height: 12)
            Text(label)
        }
    }
}

// MARK: - Detail

struct TissueDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let choice: TissueSide
    let weeksAgo: Int
    var compared = true

    var body: some View {
        let detail = model.tissueDetail(choice.tissue, side: choice.side, weeksAgo: weeksAgo)
        let name = model.library.tissue(choice.tissue)?.name ?? choice.tissue
        let hurt = model.injuries.filter { $0.isActive && $0.tissues.contains(choice.tissue) && $0.side.bodySides.contains(choice.side) }
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Int(detail.week.rounded()))").font(.largeTitle.weight(.bold).monospacedDigit())
                            Text(weeksAgo == 0 ? "effective reps, last 7 days" : "effective reps that week")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(ratioWords(detail)).font(.headline)
                            if compared {
                                Text("usual week \(Int(detail.usualWeek.rounded()))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    WeekBars(weekly: detail.weekly)
                    ForEach(hurt) { injury in
                        Label(injury.label, systemImage: "bandage.fill").foregroundStyle(.orange)
                    }
                }
                ForEach(hurt) { injury in
                    WeightMovedSection(injury: injury, weeksAgo: weeksAgo)
                }
                Section(weeksAgo == 0 ? "This week, by activity" : "That week, by activity") {
                    if detail.contributions.isEmpty {
                        Text("Nothing loaded this tissue.").foregroundStyle(.secondary)
                    }
                    ForEach(detail.contributions, id: \.exercise) { item in
                        HStack {
                            Text(item.exercise)
                            Spacer()
                            Text("\(Int(item.dose.rounded())) · \(share(item.dose, of: detail.week))")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                Section {
                } footer: {
                    Text("A set done with both sides counts in full toward each side. Daily steps count as walking load on the legs. This describes load; it is not advice.")
                }
            }
            .navigationTitle("\(Format.side(choice.side)) \(name.lowercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func ratioWords(_ detail: TissueDetail) -> String {
        if detail.week == 0 { return "no load" }
        guard let ratio = detail.ratio else { return compared ? "new" : "no usual week yet" }
        return "\(Format.ratio(ratio)) usual"
    }

    private func share(_ dose: Double, of total: Double) -> String {
        total > 0 ? "\(Int((dose / total * 100).rounded()))%" : "–"
    }
}

/// Five weeks of dose, oldest on the left; the last is the week shown.
struct WeekBars: View {
    let weekly: [Double]

    var body: some View {
        let top = max(weekly.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(weekly.enumerated()), id: \.offset) { i, value in
                VStack(spacing: 3) {
                    Text("\(Int(value.rounded()))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i == weekly.count - 1 ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(height: max(2, 60 * value / top))
                    Text(i == weekly.count - 1 ? "this" : "−\(weekly.count - 1 - i)w")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 100)
        .accessibilityElement()
        .accessibilityLabel("Last five weeks, oldest first")
        .accessibilityValue(weekly.map { "\(Int($0.rounded()))" }.joined(separator: ", "))
    }
}

/// For an injured tissue: weight moved on each side in the sheet's week by the
/// sets that load the injury, in the person's unit. The same unit on both
/// sides, unlike effective reps, which follow each side's own usual weight.
struct WeightMovedSection: View {
    @Environment(AppModel.self) private var model
    let injury: Injury
    let weeksAgo: Int

    var body: some View {
        // The timeline ends today; the sheet's week is its first seven days.
        let days = model.timeline(for: injury, days: 7 * (weeksAgo + 1)).prefix(7)
        let unit = model.profile.unit
        let injured = days.reduce(0) { $0 + $1.volumeKg }
        let other: Double? = injury.side == .both ? nil : days.reduce(0) { $0 + ($1.otherVolumeKg ?? 0) }
        let unweighed = days.reduce(0) { $0 + $1.unweighedSets }
        Section {
            if injury.side == .both {
                LabeledContent("Both sides, injured", value: Format.weight(injured, unit, decimals: false))
            } else {
                let otherSide: Side = injury.side == .left ? .right : .left
                LabeledContent("\(Format.side(injury.side)), injured", value: Format.weight(injured, unit, decimals: false))
                LabeledContent(Format.side(otherSide), value: Format.weight(other ?? 0, unit, decimals: false))
            }
        } header: {
            Text(weeksAgo == 0 ? "Weight moved, last 7 days" : "Weight moved that week")
        } footer: {
            Text("Load × reps of the sets that load \(injury.label.lowercased()), a hold counting 5 seconds as a rep. A load shared by both sides counts half for each."
                 + (unweighed > 0 ? " \(Format.count(unweighed, "set")) with no known weight \(unweighed == 1 ? "is" : "are") left out." : ""))
        }
    }
}
