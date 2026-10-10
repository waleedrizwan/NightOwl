import AVFoundation
import Foundation

/// The clips the report plays (analyze.py write_clip; publish.py's AAC):
/// each snoring bout whole plus 2 s either side, and 8 s around each possible
/// gasp, with the hum and the mic's hiss removed and turned up for listening.
public enum Clips {
    static let boutPadMs = 2_000, boutClipCap = 200
    static let gaspClipMs = 8_000, gaspPrerollMs = 3_000
    static let prerollMs = 3_000          // analyze.py CLIP_PREROLL_MS: which capture a clip belongs to

    public enum Format: Sendable { case aac, wav }

    /// Writes the night's clips into dir and returns the report with each
    /// bout's and gasp's `clip` set to "<prefix><file name>".
    public static func write(_ result: Analyzer.Result, into dir: URL, prefix: String, format: Format = .aac,
                             progress: (@Sendable (Double) -> Void)? = nil) throws -> NightReport {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = format == .aac ? "m4a" : "wav"
        var report = result.report
        let jobs = report.bouts.indices.prefix(boutClipCap).count + report.gasps.count
        var done = 0
        for i in report.bouts.indices.prefix(boutClipCap) {
            let b = report.bouts[i]
            let name = "snore_\(clock(b.startMs)).\(ext)"
            try make(result, t0: b.startMs - boutPadMs, ms: b.endMs - b.startMs + 2 * boutPadMs,
                     to: dir.appendingPathComponent(name), format: format)
            report.bouts[i].clip = prefix + name
            done += 1; progress?(Double(done) / Double(jobs))
        }
        for i in report.gasps.indices {
            let g = report.gasps[i]
            let name = "gasp_\(clock(g.tMs)).\(ext)"
            try make(result, t0: g.tMs - gaspPrerollMs, ms: gaspClipMs, to: dir.appendingPathComponent(name), format: format)
            report.gasps[i].clip = prefix + name
            done += 1; progress?(Double(done) / Double(jobs))
        }
        return report
    }

    static func make(_ r: Analyzer.Result, t0: Int, ms: Int, to url: URL, format: Format) throws {
        let segs = r.segments
        let si = segs.firstIndex { $0.anchorMs <= t0 + prerollMs && t0 + prerollMs < $0.endMs } ?? segs.count - 1
        let seg = segs[si]
        let s0 = floorDiv((t0 - seg.anchorMs) * Audio.sampleRate, 1000)
        let audio = try seg.read(s0, s0 + ms * Audio.sampleRate / 1000)
        guard !audio.isEmpty else { return }
        // hum tones and hiss profile of the file the clip starts in (measured
        // over 10 minutes, so a clip full of snoring is not mistaken for noise)
        let chunk = seg.chunks.firstIndex { $0.segmentOffset <= max(0, s0) && max(0, s0) < $0.segmentOffset + $0.count } ?? 0
        let index = segs[..<si].reduce(0) { $0 + $1.chunks.count } + chunk   // tones/profiles are per chunk, all segments
        let x = audio.map { Double($0) / 32768 }
        let clean = Denoise.boost(Denoise.denoise(Hum.removeHum(x, tones: r.tones[index]), profile: r.profiles[index]))
        // the same rounding to 16-bit as denoise.write_wav
        let pcm = clean.map { Int16(max(-32768, min(32767, ($0 * 32768).rounded(.toNearestOrEven)))) }
        try? FileManager.default.removeItem(at: url)
        switch format {
        case .wav: try writeWav(pcm, to: url)
        case .aac: try writeAAC(pcm, to: url)
        }
    }

    static func writeWav(_ pcm: [Int16], to url: URL) throws {
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: "RIFF".utf8); u32(36 + 2 * pcm.count); d.append(contentsOf: "WAVEfmt ".utf8)
        u32(16); u16(1); u16(1); u32(Audio.sampleRate); u32(2 * Audio.sampleRate); u16(2); u16(16)
        d.append(contentsOf: "data".utf8); u32(2 * pcm.count)
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: url, options: .atomic)
    }

    /// AAC in an .m4a at 32 kbit/s, like publish.py's afconvert: ~7x smaller than WAV.
    static func writeAAC(_ pcm: [Int16], to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Audio.sampleRate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: false)
        let format = file.processingFormat
        let step = 16_000 * 10
        for start in stride(from: 0, to: pcm.count, by: step) {
            let n = min(step, pcm.count - start)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { continue }
            buf.frameLength = AVAudioFrameCount(n)
            pcm.withUnsafeBufferPointer { src in
                buf.int16ChannelData![0].update(from: src.baseAddress! + start, count: n)
            }
            try file.write(from: buf)
        }
    }

    static func clock(_ ms: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Audio.timeZone
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// Python's //.
    static func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }
}
