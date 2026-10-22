import Charts
import SwiftUI

struct NightView: View {
    let night: Night
    @Environment(Store.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                stats
                throughTheNight
                if !night.bouts.isEmpty { bouts }
                if !night.gasps.isEmpty { gasps }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sky.ignoresSafeArea())
    }

    private var delta: String? {
        guard let prev = store.previous(to: night) else { return nil }
        let d = night.score - prev.score
        return d == 0 ? "Same as the night before" : "\(d > 0 ? "▲" : "▼") \(abs(d)) vs the night before"
    }

    private var header: some View {
        VStack(spacing: 14) {
            VStack(spacing: 2) {
                Text(night.date.dayLabel).font(.title3.weight(.semibold))
                Text("\(night.start.clock) – \(night.end.clock)").font(.subheadline).foregroundStyle(Theme.muted)
            }
            ScoreRing(score: night.score, band: night.band)
            if let delta {
                Text(delta).font(.subheadline).foregroundStyle(Theme.muted)
            }
            if store.isFromPhone(night) {
                Label("Analyzed on this iPhone", systemImage: "iphone").font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 8)
    }

    private var stats: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Stat(label: "Snoring", value: duration(ms: night.snoreMs), detail: "\(night.percentOfNight)% of the night")
                Stat(label: "Recorded", value: duration(ms: night.recordedMs))
            }
            GridRow {
                Stat(label: "Bouts", value: "\(night.bouts.count)")
                Stat(label: "Possible gasps", value: "\(night.gasps.count)")
            }
        }
    }

    /// Whole minutes, at least 2, so a quiet night still has visible bars.
    private var yMax: Double { max(2, (Double(night.timeline.map(\.snoreSec).max() ?? 0) / 60).rounded(.up)) }

    private var throughTheNight: some View {
        Card(title: "Through the night") {
            TimelineChart(night: night, yMax: yMax)
        }
    }

    private var bouts: some View {
        Card(title: "Snoring bouts") {
            ForEach(night.bouts, id: \.startMs) { b in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Date(ms: b.startMs).clock).font(.body.weight(.medium)).monospacedDigit()
                        Text("\(duration(ms: b.endMs - b.startMs)) · \(b.sounds) snores")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    PlayButton(clip: b.clip)
                }
                if b.startMs != night.bouts.last?.startMs { Divider().overlay(Color.white.opacity(0.08)) }
            }
        }
    }

    private var gasps: some View {
        Card(title: "Possible gasps") {
            ForEach(night.gasps, id: \.tMs) { g in
                HStack {
                    Text(Date(ms: g.tMs).clock).monospacedDigit()
                    Text("confidence \(Int(g.score * 100))%").font(.caption).foregroundStyle(Theme.muted)
                    Spacer()
                    PlayButton(clip: g.clip)
                }
            }
        }
    }
}

/// The night in 5-minute bars. Tap or drag across it to pick a moment: the
/// clip recorded there (or the nearest one) plays when you let go. Ticks along
/// the top mark where there are clips.
struct TimelineChart: View {
    let night: Night
    let yMax: Double
    @State private var selected: Int?          // startMs of the picked 5-minute bar
    private var player = ClipPlayer.shared

    init(night: Night, yMax: Double) {
        self.night = night
        self.yMax = yMax
    }

    /// Everything with a clip: (from, to, clip path, what it is).
    private var moments: [(from: Int, to: Int, clip: String, kind: String)] {
        night.bouts.compactMap { b in b.clip.map { (b.startMs, b.endMs, $0, "Snoring bout") } }
            + night.gasps.compactMap { g in g.clip.map { (g.tMs, g.tMs + 1000, $0, "Possible gasp") } }
    }

    /// The clip for a bar: one that overlaps it, else the nearest in time.
    private func moment(for bar: Int) -> (from: Int, to: Int, clip: String, kind: String)? {
        let end = bar + 300_000
        if let hit = moments.filter({ $0.from < end && $0.to > bar }).min(by: { abs($0.from - bar) < abs($1.from - bar) }) {
            return hit
        }
        func gap(_ m: (from: Int, to: Int, clip: String, kind: String)) -> Int { m.to <= bar ? bar - m.to : m.from - end }
        return moments.min { gap($0) < gap($1) }
    }

    var body: some View {
        let picked = selected.flatMap { s in night.timeline.first { $0.startMs == s } }
        let match = selected.flatMap(moment(for:))
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(night.timeline, id: \.startMs) { b in
                    RectangleMark(
                        xStart: .value("From", Date(ms: b.startMs)),
                        xEnd: .value("To", Date(ms: b.startMs + 300_000)),
                        yStart: .value("", 0),
                        yEnd: .value("Snoring (min)", Double(b.snoreSec) / 60)
                    )
                    .foregroundStyle(b.snoreSec >= 120 ? Theme.heavy : b.snoreSec >= 45 ? Theme.moderate : Theme.amber)
                    .opacity(selected == nil || selected == b.startMs ? 1 : 0.35)
                    .cornerRadius(2)
                }
                ForEach(moments, id: \.clip) { m in
                    PointMark(x: .value("Clip", Date(ms: m.from)), y: .value("", yMax))
                        .symbol(.circle).symbolSize(14)
                        .foregroundStyle(.white.opacity(0.45))
                }
                if let s = selected {
                    RuleMark(x: .value("Picked", Date(ms: s + 150_000)))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: 0...yMax)
            .chartYAxis {
                AxisMarks(values: Array(0...Int(yMax))) { v in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel { if let m = v.as(Int.self) { Text("\(m)m") } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    // tap = pick and play; a sideways drag scrubs and plays on release;
                    // an up/down swipe is left to the page's scroll
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { pick(at: $0.location, proxy, geo); playPicked() })
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { d in
                                    if abs(d.translation.width) > abs(d.translation.height) { pick(at: d.location, proxy, geo) }
                                }
                                .onEnded { d in
                                    if abs(d.translation.width) > abs(d.translation.height) { pick(at: d.location, proxy, geo); playPicked() }
                                }
                        )
                }
            }
            .frame(height: 190)

            if let s = selected {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Date(ms: s).clock) – \(Date(ms: s + 300_000).clock)").font(.body.weight(.medium)).monospacedDigit()
                        Text(detail(picked?.snoreSec ?? 0, match, bar: s)).font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    PlayButton(clip: match?.clip)
                }
                .padding(10)
                .background(.white.opacity(0.05), in: .rect(cornerRadius: 10))
            } else {
                Text(moments.isEmpty ? "Minutes of snoring in each 5 minutes."
                                     : "Minutes of snoring in each 5 minutes. Tap or drag across it to listen; dots mark the clips.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    private func detail(_ snoreSec: Int, _ m: (from: Int, to: Int, clip: String, kind: String)?, bar: Int) -> String {
        let here = snoreSec == 0 ? "No snoring" : "\(duration(ms: snoreSec * 1000)) snoring"
        guard let m else { return here + " · no clips this night" }
        let inside = m.from < bar + 300_000 && m.to > bar
        return here + " · " + (inside ? "\(m.kind) at \(Date(ms: m.from).clock)"
                                     : "nearest clip: \(m.kind.lowercased()) at \(Date(ms: m.from).clock)")
    }

    private func pick(at point: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy) {
        guard let plot = proxy.plotFrame else { return }
        let x = point.x - geo[plot].origin.x
        guard let date: Date = proxy.value(atX: x) else { return }
        let ms = Int(date.timeIntervalSince1970 * 1000)
        // the bar under the finger, or the closest one when between/outside bars
        guard let bar = night.timeline.min(by: { abs($0.startMs + 150_000 - ms) < abs($1.startMs + 150_000 - ms) }) else { return }
        if selected != bar.startMs {
            selected = bar.startMs
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func playPicked() {
        guard let s = selected, let clip = moment(for: s)?.clip, player.playing != clip else { return }
        Task { await player.toggle(clip) }
    }
}
