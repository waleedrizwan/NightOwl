import AVFoundation
import SwiftUI

enum Theme {
    static let amber = Color(red: 0.96, green: 0.77, blue: 0.38)
    static let quiet = Color(red: 0.40, green: 0.80, blue: 0.58)
    static let light = Color(red: 0.96, green: 0.77, blue: 0.38)
    static let moderate = Color(red: 0.95, green: 0.52, blue: 0.20)
    static let heavy = Color(red: 0.96, green: 0.30, blue: 0.24)
    static let card = Color.white.opacity(0.06)
    static let muted = Color.white.opacity(0.55)
    static let sky = LinearGradient(colors: [Color(red: 0.10, green: 0.13, blue: 0.27), Color(red: 0.03, green: 0.04, blue: 0.10)],
                                    startPoint: .top, endPoint: .bottom)

    static func color(_ band: String) -> Color {
        switch band {
        case "quiet": quiet
        case "light": light
        case "moderate": moderate
        default: heavy
        }
    }

    static func band(_ score: Int) -> String {
        switch score {
        case ..<10: "quiet"
        case ..<25: "light"
        case ..<50: "moderate"
        default: "heavy"
        }
    }
}

// MARK: - Formatting

func duration(ms: Int) -> String {
    let m = Int((Double(ms) / 60_000).rounded())
    if m == 0 { return ms > 0 ? "<1 m" : "none" }
    return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60)) m" : "\(m) m"
}

extension Date {
    var clock: String { formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()) }
    var dayLabel: String { formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
    var shortDay: String { formatted(.dateTime.month(.abbreviated).day()) }
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title { Text(title).font(.headline) }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct Stat: View {
    let label: String, value: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Theme.muted)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            if let detail { Text(detail).font(.caption).foregroundStyle(Theme.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ScorePill: View {
    let score: Int, band: String
    var body: some View {
        Text("\(score)")
            .font(.subheadline.weight(.bold)).monospacedDigit()
            .frame(minWidth: 36).padding(.vertical, 4).padding(.horizontal, 6)
            .background(Theme.color(band).opacity(0.9), in: Capsule())
            .foregroundStyle(.black.opacity(0.8))
    }
}

struct ScoreRing: View {
    let score: Int, band: String
    @State private var shown = 0.0
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 18)
            Circle()
                .trim(from: 0, to: max(0.02, shown / 100))
                .stroke(Theme.color(band).gradient, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text("\(score)").font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
                Text(band.uppercased()).font(.caption.weight(.semibold)).tracking(2).foregroundStyle(Theme.color(band))
            }
        }
        .frame(width: 200, height: 200)
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { shown = Double(score) } }
        .onChange(of: score) { _, s in withAnimation(.easeOut(duration: 0.6)) { shown = Double(s) } }
        .accessibilityElement().accessibilityLabel("Snore Score \(score), \(band)")
    }
}

// MARK: - Clip playback

@Observable
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = ClipPlayer()
    private(set) var playing: String?
    private(set) var loading: String?
    private var player: AVAudioPlayer?

    @MainActor
    func toggle(_ path: String) async {
        if playing == path { stop(); return }
        stop()
        loading = path
        defer { loading = nil }
        do {
            let url = try await Store.shared.clipFile(path)
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.play()
            playing = path
        } catch {
            print("clip failed: \(error)")
        }
    }

    func stop() { player?.stop(); player = nil; playing = nil }
    func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) { playing = nil }
}

struct PlayButton: View {
    let clip: String?
    private var player = ClipPlayer.shared
    init(clip: String?) { self.clip = clip }
    var body: some View {
        if let clip {
            Button { Task { await player.toggle(clip) } } label: {
                Group {
                    if player.loading == clip { ProgressView() }
                    else { Image(systemName: player.playing == clip ? "stop.fill" : "play.fill") }
                }
                .frame(width: 36, height: 36)
                .background(Theme.amber.opacity(0.18), in: Circle())
                .foregroundStyle(Theme.amber)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.playing == clip ? "Stop clip" : "Play clip")
        }
    }
}
