import Accelerate
import CoreML
import Foundation

public enum AnalysisError: Error, CustomStringConvertible {
    case modelMissing, classMissing(String), badOutput
    public var description: String {
        switch self {
        case .modelMissing: "YAMNet model missing from the app"
        case .classMissing(let c): "class map is missing \(c); wrong model?"
        case .badOutput: "YAMNet returned no scores"
        }
    }
}

/// One 500 ms frame: the levels and scores the counting rules look at.
public struct Frame: Sendable {
    public let tMs: Int              // window START (spec §0)
    public let rmsDbfs: Double
    public let peakDbfs: Double
    public var noiseFloor: Double = 0
    public let snoring: Float, speech: Float, gasp: Float
}

/// analyze.py's AI-mode analysis of one night folder, minus clips and the HTML report.
public struct Analyzer: Sendable {
    // DetectorParams defaults (detector.py) the AI-mode rules use
    static let confThreshold: Float = 0.35, speechVeto: Float = 0.50
    static let hopMs = 500, windowMs = 1000, mergeGapMs = 30_000
    static let nfInit = -60.0, nfRisePerFrame = 0.05, nfLo = -80.0, nfHi = -30.0
    static let aiMinSounds = 4
    static let gaspMinScore: Float = 0.15, gaspMinAboveFloorDb = 6.0, gaspMergeMs = 5_000, gaspMax = 10
    static let binMs = 300_000

    public var workers: Int
    public var computeUnits: MLComputeUnits

    public init(workers: Int = 2, computeUnits: MLComputeUnits = .all) {
        self.workers = workers
        self.computeUnits = computeUnits
    }

    public struct Result: Sendable {
        public let report: NightReport
        public let frames: [Frame]
        public let tonesPerFile: [String: [Double]]
        public let seconds: Double
        // for the clips (Clips.swift): per chunk, in segment order
        let segments: [Segment]
        let tones: [[Double]]
        let profiles: [[Float]]
    }

    public func analyze(night dir: URL, progress: (@Sendable (String, Double) -> Void)? = nil) async throws -> Result {
        let started = Date()
        let segments = try Recording.segments(in: dir)
        let chunks = segments.enumerated().flatMap { si, seg in seg.chunks.map { (si, seg.anchorMs, $0) } }
        let lanes = max(1, min(workers, chunks.count))

        // pass 1: steady tones per file, then the night-wide ones added to each file
        progress?("Finding steady hums", 0)
        let perFile = try await inLanes(chunks.count, lanes) { i in Hum.findTones(try chunks[i].2.samples()) }
        let common = Hum.nightTones(perFile)
        let tones = perFile.map { Hum.mergeTones($0, common) }

        // pass 2: per file, hum-free audio → levels + YAMNet for every frame whose
        // 1 s window lies inside the file; keep its first and last second for
        // the frames that straddle the boundary with the file before
        let done = Counter()
        let parts = try await inLanes(chunks.count, lanes, perLane: { try YAMNet(computeUnits: computeUnits) }) { i, model in
            let (_, anchor, c) = chunks[i]
            let clean = Hum.removeHum(try c.samples(), tones: tones[i])
            let ends = Self.frameEnds(c).filter { $0 - Audio.window >= c.segmentOffset }
            let frames = try Self.frames(ends: ends, buffer: clean, bufferStart: c.segmentOffset, anchorMs: anchor, model: model)
            // hiss profile of the whole file, for cleaning the clips that start in it
            let profile = Denoise.noiseProfile(clean)
            progress?("Listening", Double(done.increment()) / Double(chunks.count))
            return (frames, head: Array(clean.prefix(Audio.window)), tail: Array(clean.suffix(Audio.window)), profile: profile)
        }
        let model = try YAMNet(computeUnits: computeUnits)
        var frames: [Frame] = []
        var segmentOfFrame: [Int] = []
        for (i, (si, anchor, c)) in chunks.enumerated() {
            if c.segmentOffset > 0 {    // windows reaching back into the previous file
                let ends = Self.frameEnds(c).filter { $0 - Audio.window < c.segmentOffset }
                let buffer = parts[i - 1].tail + parts[i].head
                let edge = try Self.frames(ends: ends, buffer: buffer, bufferStart: c.segmentOffset - Audio.window,
                                           anchorMs: anchor, model: model)
                frames += edge
                segmentOfFrame += Array(repeating: si, count: edge.count)
            }
            frames += parts[i].0
            segmentOfFrame += Array(repeating: si, count: parts[i].0.count)
        }

        // the detector's noise floor, frame by frame (it carries across capture gaps)
        var nf = Self.nfInit
        for k in frames.indices {
            nf = min(max(min(frames[k].rmsDbfs, nf + Self.nfRisePerFrame), Self.nfLo), Self.nfHi)
            frames[k].noiseFloor = nf
        }

        let report = NightReport.make(dir: dir.lastPathComponent, segments: segments, frames: frames,
                                      bouts: Self.bouts(frames), gasps: Self.gasps(frames))
        return Result(report: report, frames: frames,
                      tonesPerFile: Dictionary(uniqueKeysWithValues: zip(chunks.map { $0.2.url.lastPathComponent }, tones)),
                      seconds: Date().timeIntervalSince(started),
                      segments: segments, tones: tones, profiles: parts.map(\.profile))
    }

    /// Segment sample indices where this chunk's frames end (analyze.py: `ends`).
    static func frameEnds(_ c: Chunk) -> [Int] {
        let before = c.segmentOffset, after = c.segmentOffset + c.count
        let first = max(Audio.window, (before / Audio.hop + 1) * Audio.hop)
        return first <= after ? Array(stride(from: first, through: after, by: Audio.hop)) : []
    }

    static func frames(ends: [Int], buffer: [Float], bufferStart: Int, anchorMs: Int, model: YAMNet) throws -> [Frame] {
        guard !ends.isEmpty else { return [] }
        let windows = ends.map { e in buffer[(e - Audio.classifierWindow - bufferStart)..<(e - bufferStart)] }
        let scores = try model.scores(windows)
        return ends.enumerated().map { k, e in
            let w = buffer[(e - Audio.window - bufferStart)..<(e - bufferStart)]
            var sum = 0.0, peak: Float = 0
            for v in w { sum += Double(v) * Double(v); peak = max(peak, abs(v)) }
            return Frame(tMs: anchorMs + (e - Audio.window) * 1000 / Audio.sampleRate,
                         rmsDbfs: dbfs((sum / Double(w.count)).squareRoot()), peakDbfs: dbfs(Double(peak)),
                         snoring: scores[k][YAMNet.Col.snoring], speech: scores[k][YAMNet.Col.speech],
                         gasp: scores[k][YAMNet.Col.gasp])
        }
    }

    static func dbfs(_ x: Double) -> Double { x > 0 ? min(max(20 * log10(x), -100), 0) : -100 }

    // MARK: counting (analyze.py detect_bouts, find_gasps)

    public struct Bout: Sendable, Codable, Hashable {
        public let startMs: Int, endMs: Int, sounds: Int, soundStarts: [Int], maxScore: Double, peakMs: Int
    }

    /// A snore sound is a run of frames with snoring >= the threshold and no
    /// speech veto; sounds within the merge gap form a bout; a bout needs
    /// aiMinSounds sounds, so one isolated sound never counts.
    static func bouts(_ frames: [Frame]) -> [Bout] {
        var events: [(start: Int, end: Int, max: Float, at: Int)] = []
        var last: Int?
        for f in frames {
            if f.snoring < confThreshold || (f.speech >= speechVeto && f.speech > f.snoring) { continue }
            if let l = last, f.tMs - l == hopMs {
                events[events.count - 1].end = f.tMs + windowMs
                if f.snoring > events[events.count - 1].max { events[events.count - 1].max = f.snoring; events[events.count - 1].at = f.tMs }
            } else {
                events.append((f.tMs, f.tMs + windowMs, f.snoring, f.tMs))
            }
            last = f.tMs
        }
        var groups: [[(start: Int, end: Int, max: Float, at: Int)]] = []
        for ev in events {
            if let g = groups.last, ev.start - g.last!.end <= mergeGapMs { groups[groups.count - 1].append(ev) } else { groups.append([ev]) }
        }
        return groups.filter { $0.count >= aiMinSounds }.map { g in
            let top = g.reduce(g[0]) { $1.max > $0.max ? $1 : $0 }
            return Bout(startMs: g[0].start, endMs: g.last!.end, sounds: g.count, soundStarts: g.map(\.start),
                        maxScore: round2(Double(top.max)), peakMs: top.at)
        }
    }

    public struct Gasp: Sendable, Codable, Hashable { public let tMs: Int, score: Double }

    /// YAMNet's Gasp class is uncalibrated for a bedside mic: these surface
    /// moments worth listening to, ranked; they are not counted.
    static func gasps(_ frames: [Frame]) -> [Gasp] {
        var groups: [[(t: Int, s: Float)]] = []
        for f in frames where f.gasp >= gaspMinScore && f.rmsDbfs >= f.noiseFloor + gaspMinAboveFloorDb {
            if let g = groups.last, f.tMs - g.last!.t <= gaspMergeMs { groups[groups.count - 1].append((f.tMs, f.gasp)) }
            else { groups.append([(f.tMs, f.gasp)]) }
        }
        let best = groups.map { g in g.reduce(g[0]) { $1.s > $0.s ? $1 : $0 } }
        let top = best.enumerated().sorted { $0.element.s != $1.element.s ? $0.element.s > $1.element.s : $0.offset < $1.offset }
            .prefix(gaspMax).map(\.element)
        return top.sorted { $0.t < $1.t }.map { Gasp(tMs: $0.t, score: round2(Double($0.s))) }
    }

    // MARK: lanes

    /// Runs work(0..<count) on `lanes` concurrent workers; results in index order.
    func inLanes<T: Sendable>(_ count: Int, _ lanes: Int, _ work: @escaping @Sendable (Int) throws -> T) async throws -> [T] {
        try await inLanes(count, lanes, perLane: { () }) { i, _ in try work(i) }
    }

    func inLanes<T: Sendable, L>(_ count: Int, _ lanes: Int, perLane: @escaping @Sendable () throws -> L,
                                 _ work: @escaping @Sendable (Int, L) throws -> T) async throws -> [T] {
        try await withThrowingTaskGroup(of: [(Int, T)].self) { group in
            for lane in 0..<lanes {
                group.addTask {
                    let state = try perLane()
                    var out: [(Int, T)] = []
                    for i in stride(from: lane, to: count, by: lanes) {
                        try Task.checkCancellation()
                        out.append((i, try autoreleasepool { try work(i, state) }))
                    }
                    return out
                }
            }
            var results = [T?](repeating: nil, count: count)
            for try await part in group { for (i, r) in part { results[i] = r } }
            return results.map { $0! }
        }
    }
}

final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

/// Python's round(x, 2).
func round2(_ x: Double) -> Double { (x * 100).rounded(.toNearestOrEven) / 100 }

#if !canImport(ObjectiveC)
func autoreleasepool<T>(_ body: () throws -> T) rethrows -> T { try body() }
#endif
