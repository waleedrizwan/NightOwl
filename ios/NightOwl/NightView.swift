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
            Chart(night.timeline, id: \.startMs) { b in
                RectangleMark(
                    xStart: .value("From", Date(ms: b.startMs)),
                    xEnd: .value("To", Date(ms: b.startMs + 300_000)),
                    yStart: .value("", 0),
                    yEnd: .value("Snoring (min)", Double(b.snoreSec) / 60)
                )
                .foregroundStyle(b.snoreSec >= 120 ? Theme.heavy : b.snoreSec >= 45 ? Theme.moderate : Theme.amber)
                .cornerRadius(2)
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
            .frame(height: 170)
            Text("Minutes of snoring in each 5 minutes.").font(.caption).foregroundStyle(Theme.muted)
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
