import Charts
import RehabitCore
import SwiftUI

/// Load on the injured side per day (and the other side, lighter), with the
/// day's pain range on a 0 to 10 scale at the right and flare-ups marked.
struct LoadPainChart: View {
    @Environment(AppModel.self) private var model
    let injury: Injury
    @State private var weeks = 6
    @State private var selected: Date?

    var body: some View {
        let days = model.timeline(for: injury, days: weeks * 7)
        let top = max(days.map { max($0.load, $0.otherLoad ?? 0) }.max() ?? 0, 1)
        let scale = top / 10           // pain 10 sits at the top of the load axis
        let sideName = injury.side == .both ? "Load" : "\(Format.side(injury.side)) side"
        VStack(alignment: .leading, spacing: 10) {
            Picker("Period", selection: $weeks) {
                Text("2 weeks").tag(2)
                Text("6 weeks").tag(6)
                Text("12 weeks").tag(12)
            }
            .pickerStyle(.segmented)
            Chart {
                ForEach(days) { d in
                    let date = Format.date(d.day)
                    BarMark(x: .value("Day", date, unit: .day), y: .value("Load", d.load))
                        .foregroundStyle(by: .value("Series", sideName))
                        .position(by: .value("Side", "injured"))
                    if let other = d.otherLoad {
                        BarMark(x: .value("Day", date, unit: .day), y: .value("Load", other))
                            .foregroundStyle(by: .value("Series", "Other side"))
                            .position(by: .value("Side", "other"))
                    }
                    if let low = d.painLow, let high = d.painHigh {
                        RuleMark(x: .value("Day", date, unit: .day), yStart: .value("Pain", low * scale),
                                 yEnd: .value("Pain", max(high, low + 0.15) * scale))
                            .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round))
                            .foregroundStyle(Color.pink)
                        PointMark(x: .value("Day", date, unit: .day), y: .value("Pain", high * scale))
                            .symbolSize(30)
                            .foregroundStyle(Color.pink)
                    }
                    if let during = d.setPain {
                        PointMark(x: .value("Day", date, unit: .day), y: .value("Pain", during * scale))
                            .symbol(.triangle)
                            .symbolSize(50)
                            .foregroundStyle(Color.purple)
                    }
                    if let flare = d.flare {
                        PointMark(x: .value("Day", date, unit: .day), y: .value("Pain", flare * scale))
                            .symbol(.diamond)
                            .symbolSize(70)
                            .foregroundStyle(Color.orange)
                    }
                }
                if let selected {
                    RuleMark(x: .value("Day", selected, unit: .day))
                        .foregroundStyle(Color.secondary.opacity(0.4))
                }
            }
            .chartForegroundStyleScale([sideName: Color.accentColor, "Other side": Color.accentColor.opacity(0.3)])
            .chartYAxis {
                AxisMarks(position: .leading)
                AxisMarks(position: .trailing, values: [0, 5, 10].map { $0 * scale }) { value in
                    AxisGridLine().foregroundStyle(.clear)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text("pain \(Int((v / scale).rounded()))").foregroundStyle(Color.pink) }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { tap in
                            guard let plot = proxy.plotFrame else { return }
                            let x = tap.location.x - geo[plot].origin.x
                            selected = proxy.value(atX: x, as: Date.self)
                        })
                }
            }
            .frame(height: 220)
            .accessibilityLabel("Load on the \(sideName.lowercased()) and pain over \(weeks) weeks")

            dayDetail(days)
            HStack(spacing: 14) {
                legend(Color.pink, "pain range", line: true)
                HStack(spacing: 4) {
                    Image(systemName: "triangle.fill").foregroundStyle(Color.purple)
                    Text("pain during sets").foregroundStyle(.secondary)
                }
                legend(Color.orange, "flare-up", line: false)
            }
            .font(.caption)
            Text("Load is in effective reps: reps at your usual weight, heavier sets counting more.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func dayDetail(_ days: [InjuryDay]) -> some View {
        if let selected, let d = days.first(where: { Calendar.current.isDate(Format.date($0.day), inSameDayAs: selected) }) {
            var parts = ["\(Format.day(d.day))", d.trained ? "session" : "no session",
                         "load \(Int(d.load.rounded()))"]
            if let other = d.otherLoad { parts.append("other side \(Int(other.rounded()))") }
            if let low = d.painLow, let high = d.painHigh {
                parts.append(low == high ? "pain \(Format.number(low))" : "pain \(Format.number(low)) to \(Format.number(high))")
            }
            if let during = d.setPain { parts.append("pain during sets up to \(Format.number(during))") }
            if let flare = d.flare { parts.append("flare-up \(Format.number(flare))") }
            return AnyView(Text(parts.joined(separator: " · ")).font(.subheadline))
        } else {
            return AnyView(Text("Touch a day to see its numbers.").font(.caption).foregroundStyle(.secondary))
        }
    }

    private func legend(_ color: Color, _ text: String, line: Bool) -> some View {
        HStack(spacing: 4) {
            if line { Capsule().fill(color).frame(width: 4, height: 12) } else { Image(systemName: "diamond.fill").foregroundStyle(color) }
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// The core's plain report, shown, shared as text, or saved as a PDF.
struct TherapistReportView: View {
    @Environment(AppModel.self) private var model
    let injury: Injury
    @State private var weeks = 4
    @State private var pdf: URL?

    var body: some View {
        let text = model.reportText(for: injury, days: weeks * 7)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Period", selection: $weeks) {
                    Text("2 weeks").tag(2)
                    Text("4 weeks").tag(4)
                    Text("8 weeks").tag(8)
                }
                .pickerStyle(.segmented)
                HStack {
                    ShareLink(item: text, subject: Text("Rehabit report: \(injury.label)"),
                              preview: SharePreview("Rehabit report: \(injury.label)")) {
                        Label("Share as text", systemImage: "square.and.arrow.up")
                    }
                    if let pdf {
                        ShareLink(item: pdf) { Label("Share PDF", systemImage: "doc.richtext") }
                    } else {
                        Button { pdf = renderPDF(text) } label: { Label("Make a PDF", systemImage: "doc.richtext") }
                    }
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
                MarkdownReport(text: text)
            }
            .padding(16)
        }
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: text, subject: Text("Rehabit report: \(injury.label)"),
                          preview: SharePreview("Rehabit report: \(injury.label)")) {
                    Label("Share text", systemImage: "square.and.arrow.up")
                }
            }
        }
        .onChange(of: weeks) { _, _ in pdf = nil }
    }

    /// The same report laid out on A4-ish pages (a tall page, split by height).
    @MainActor private func renderPDF(_ text: String) -> URL? {
        let width: CGFloat = 595, pageHeight: CGFloat = 842, margin: CGFloat = 36
        let renderer = ImageRenderer(content: MarkdownReport(text: text)
            .padding(margin).frame(width: width, alignment: .leading)
            .environment(\.colorScheme, .light).background(Color.white))
        let safe = injury.label.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Rehabit report - \(safe).pdf")
        var ok = false
        renderer.render { size, draw in
            var box = CGRect(x: 0, y: 0, width: width, height: pageHeight)
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            var offset: CGFloat = 0
            repeat {
                pdf.beginPDFPage(nil)
                pdf.translateBy(x: 0, y: pageHeight - size.height + offset)
                draw(pdf)
                pdf.endPDFPage()
                offset += pageHeight
            } while offset < size.height
            pdf.closePDF()
            ok = true
        }
        return ok ? url : nil
    }
}

/// A small Markdown renderer for the report: headings, paragraphs and lists
/// line by line, and pipe tables as a grid.
struct MarkdownReport: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let line):
                    Text(inline(line)).font(level == 1 ? .title2.bold() : level == 2 ? .headline : .subheadline.bold())
                        .padding(.top, level == 1 ? 0 : 6)
                case .paragraph(let line):
                    Text(inline(line)).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                case .table(let rows):
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                            GridRow {
                                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                    Text(inline(cell)).font(index == 0 ? .caption.bold() : .caption)
                                }
                            }
                            if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .textSelection(.enabled)
    }

    enum Block { case heading(Int, String), paragraph(String), table([[String]]) }

    private var blocks: [Block] {
        var out: [Block] = [], table: [[String]] = []
        func flush() { if !table.isEmpty { out.append(.table(table)); table = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") {
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // Skip the |---|---| separator row.
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                continue
            }
            flush()
            if line.isEmpty { continue }
            let hashes = line.prefix { $0 == "#" }.count
            if hashes > 0 { out.append(.heading(hashes, String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces))) }
            else { out.append(.paragraph(line.hasPrefix("- ") ? "•  " + line.dropFirst(2) : line)) }
        }
        flush()
        return out
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}
