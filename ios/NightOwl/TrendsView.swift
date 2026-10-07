import Charts
import SwiftUI

struct TrendsView: View {
    @Environment(Store.self) private var store
    @State private var range = 30

    private var nights: [Night] { Array(store.nights.suffix(range == 0 ? .max : range)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Range", selection: $range) {
                        Text("7 nights").tag(7)
                        Text("30 nights").tag(30)
                        Text("All").tag(0)
                    }
                    .pickerStyle(.segmented)
                    summary
                    scoreChart
                    snoringChart
                    heatmap
                }
                .padding(16)
            }
            .background(Theme.sky.ignoresSafeArea())
            .navigationTitle("Trends")
            .refreshable { await store.refresh() }
        }
    }

    private var summary: some View {
        let avg = nights.isEmpty ? 0 : Int((Double(nights.map(\.score).reduce(0, +)) / Double(nights.count)).rounded())
        let avgSnore = nights.isEmpty ? 0 : nights.map(\.snoreMs).reduce(0, +) / nights.count
        let best = nights.min { $0.score < $1.score }
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Stat(label: "Average score", value: "\(avg)", detail: Theme.band(avg))
                Stat(label: "Average snoring", value: duration(ms: avgSnore), detail: "per night")
            }
            GridRow {
                Stat(label: "Quietest night", value: best.map { "\($0.score)" } ?? "–", detail: best?.date.dayLabel)
                Stat(label: "Nights tracked", value: "\(nights.count)", detail: nights.first.map { "since \($0.date.shortDay)" })
            }
        }
    }

    /// 7-night rolling average, aligned with `nights`.
    private var rolling: [(Date, Double)] {
        nights.indices.map { i in
            let w = nights[max(0, i - 6)...i]
            return (nights[i].date, Double(w.map(\.score).reduce(0, +)) / Double(w.count))
        }
    }

    private var scoreChart: some View {
        Card(title: "Snore Score") {
            Chart {
                ForEach(nights) { n in
                    BarMark(x: .value("Night", n.date, unit: .day), y: .value("Score", n.score))
                        .foregroundStyle(Theme.color(n.band))
                        .cornerRadius(4)
                }
                if nights.count >= 3 {
                    ForEach(rolling, id: \.0) { d, v in
                        LineMark(x: .value("Night", d, unit: .day), y: .value("7-night average", v))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    }
                }
            }
            .chartYScale(domain: 0...max(60, (nights.map(\.score).max() ?? 0) + 5))
            .chartXAxis { dayAxis }
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(.white.opacity(0.08)); AxisValueLabel() } }
            .frame(height: 200)
            HStack(spacing: 12) {
                ForEach([("quiet", "0–9"), ("light", "10–24"), ("moderate", "25–49"), ("heavy", "50+")], id: \.0) { b, r in
                    HStack(spacing: 4) {
                        Circle().fill(Theme.color(b)).frame(width: 8, height: 8)
                        Text("\(b) \(r)")
                    }
                }
            }
            .font(.caption2).foregroundStyle(Theme.muted)
        }
    }

    private var snoringChart: some View {
        Card(title: "Minutes snoring") {
            Chart(nights) { n in
                BarMark(x: .value("Night", n.date, unit: .day), y: .value("Minutes", n.snoreMinutes))
                    .foregroundStyle(Theme.amber.gradient)
                    .cornerRadius(4)
            }
            .chartXAxis { dayAxis }
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(.white.opacity(0.08)); AxisValueLabel() } }
            .frame(height: 160)
        }
    }

    private var heatmap: some View {
        let shown = Array(nights.suffix(14))
        return Card(title: "When you snore") {
            Chart {
                ForEach(shown) { n in
                    ForEach(n.snoreByHour, id: \.hour) { h in
                        RectangleMark(x: .value("Hour", String(format: "%02d", h.hour)),
                                      y: .value("Night", n.date.shortDay),
                                      width: .ratio(0.88), height: .ratio(0.82))
                            .foregroundStyle(h.minutes < 0.5 ? Color.white.opacity(0.05)
                                             : Theme.heavy.opacity(min(1, 0.25 + h.minutes / 15)))
                            .cornerRadius(3)
                    }
                }
            }
            .chartYScale(domain: shown.reversed().map(\.date.shortDay))
            .chartYAxis { AxisMarks(position: .leading) { AxisValueLabel() } }
            .chartXAxis { AxisMarks { AxisValueLabel() } }
            .frame(height: CGFloat(max(3, shown.count)) * 26 + 30)
            Text("Minutes of snoring in each clock hour, last \(shown.count) nights. Brighter = more.")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private var dayAxis: some AxisContent {
        AxisMarks(values: .stride(by: .day, count: max(1, nights.count / 6))) { _ in
            AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true)
        }
    }
}
