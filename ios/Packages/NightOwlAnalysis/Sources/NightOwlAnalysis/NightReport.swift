import Foundation

/// One night as the app shows it: the same fields, names and rounding as the
/// Mac's nights.json (analyze.py summary → dashboard.py compact → publish.py),
/// so the app can read either.
public struct NightReport: Codable, Sendable, Hashable {
    public struct HourBin: Codable, Sendable, Hashable { public let hour: Int; public let minutes: Double }
    public struct Bin: Codable, Sendable, Hashable { public let startMs: Int; public let snoreSec: Int }
    public struct Bout: Codable, Sendable, Hashable {
        public let startMs: Int, endMs: Int, sounds: Int, maxScore: Double
        public var clip: String?
    }
    public struct Gasp: Codable, Sendable, Hashable {
        public let tMs: Int, score: Double
        public var clip: String?
    }

    public let night: String, dir: String
    public let score: Int, band: String
    public let startMs: Int, endMs: Int, recordedMs: Int, snoreMs: Int, percentOfNight: Int
    public let snoreByHour: [HourBin]
    public let timeline: [Bin]
    public var bouts: [Bout]
    public var gasps: [Gasp]

    static let heatHours = 0..<13          // dashboard.py HEAT_FROM, HEAT_TO: 00:00–12:59 local

    static func make(dir: String, segments: [Segment], frames: [Frame],
                     bouts: [Analyzer.Bout], gasps: [Analyzer.Gasp]) -> NightReport {
        let start = segments[0].anchorMs, end = segments[segments.count - 1].endMs
        let recordedMs = segments.reduce(0) { $0 + $1.count } * 1000 / Audio.sampleRate
        let snoreMs = bouts.reduce(0) { $0 + $1.endMs - $1.startMs }

        var timeline: [Bin] = []
        for b0 in stride(from: start, to: end, by: Analyzer.binMs) {
            let b1 = min(b0 + Analyzer.binMs, end)
            let ms = bouts.reduce(0) { $0 + max(0, min(b1, $1.endMs) - max(b0, $1.startMs)) }
            timeline.append(Bin(startMs: b0, snoreSec: pyRound(Double(ms) / 1000)))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Audio.timeZone
        var hours = [Double](repeating: 0, count: heatHours.count)
        for b in timeline {
            let h = calendar.component(.hour, from: Date(timeIntervalSince1970: Double(b.startMs) / 1000))
            if heatHours.contains(h) { hours[h - heatHours.lowerBound] += Double(b.snoreSec) / 60 }
        }
        let score = snoreScore(recordedMs: recordedMs, snoreMs: snoreMs, gasps: gasps.count)
        return NightReport(
            night: nightOf(start), dir: dir, score: score, band: band(score),
            startMs: start, endMs: end, recordedMs: recordedMs, snoreMs: snoreMs,
            percentOfNight: pyRound(100 * Double(snoreMs) / Double(max(1, end - start))),
            snoreByHour: hours.enumerated().map { HourBin(hour: heatHours.lowerBound + $0, minutes: round2($1)) },
            timeline: timeline,
            bouts: bouts.map { Bout(startMs: $0.startMs, endMs: $0.endMs, sounds: $0.sounds, maxScore: $0.maxScore) },
            gasps: gasps.map { Gasp(tMs: $0.tMs, score: $0.score) })
    }

    /// score.py: 5 × (minutes of snoring per hour recorded) + 1 per possible gasp, capped at 100.
    public static func snoreScore(recordedMs: Int, snoreMs: Int, gasps: Int) -> Int {
        let hours = Double(max(recordedMs, 1)) / 3_600_000
        let perHour = Double(snoreMs) / 60_000 / hours
        return min(100, pyRound(5 * perHour + Double(gasps)))
    }

    public static func band(_ score: Int) -> String {
        score < 10 ? "quiet" : score < 25 ? "light" : score < 50 ? "moderate" : "heavy"
    }

    /// Spec §3.1: the night a recording belongs to is the local date of (start − 12 h).
    static func nightOf(_ ms: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Audio.timeZone
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000 - 12 * 3600))
    }
}

/// Python's round(): halves go to the even neighbour.
func pyRound(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }
