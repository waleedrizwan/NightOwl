import Foundation

/// One night's 10-minute WAV files, grouped into uninterrupted captures
/// (analyze.py: Chunk, Segment, parse_wav, load_segments).
public enum Audio {
    public static let sampleRate = 16_000
    public static let hop = 8_000            // spec HOP_MS = 500
    public static let window = 16_000        // spec WINDOW_MS = 1000, level window
    public static let classifierWindow = 15_600   // one YAMNet patch, 0.975 s
    static let contiguousToleranceMs = 2_000      // chunk boundaries closer than this are one capture

    /// The recorder's clock and file names are in this zone, wherever the phone is.
    public static let timeZone = TimeZone(identifier: "America/Toronto")!
}

public struct Chunk: Sendable {
    public let url: URL
    public let wallStartMs: Int          // from the file name (recorder's clock at file open)
    let dataOffset: Int
    public let count: Int                // samples
    public internal(set) var segmentOffset = 0   // index of this chunk's first sample within its segment

    /// int16 samples scaled to ±1, as Double.
    func samples() throws -> [Double] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: dataOffset)
            return (0..<count).map { i in
                Double(Int16(littleEndian: base.loadUnaligned(fromByteOffset: 2 * i, as: Int16.self))) / 32768
            }
        }
    }

    func int16Samples(_ range: Range<Int>) throws -> [Int16] {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: dataOffset)
            return range.map { Int16(littleEndian: base.loadUnaligned(fromByteOffset: 2 * $0, as: Int16.self)) }
        }
    }
}

/// One uninterrupted capture: timestamps come from its sample count.
public struct Segment: Sendable {
    public let anchorMs: Int
    public internal(set) var chunks: [Chunk]

    public var count: Int { chunks.reduce(0) { $0 + $1.count } }
    public var endMs: Int { anchorMs + count * 1000 / Audio.sampleRate }

    /// int16 samples [s0, s1) of this segment, clamped to what exists.
    func read(_ s0: Int, _ s1: Int) throws -> [Int16] {
        let s0 = max(0, s0), s1 = min(count, s1)
        var out: [Int16] = []
        for c in chunks {
            let a = max(s0, c.segmentOffset), b = min(s1, c.segmentOffset + c.count)
            if a < b { out += try c.int16Samples((a - c.segmentOffset)..<(b - c.segmentOffset)) }
        }
        return out
    }
}

public enum RecordingError: Error, CustomStringConvertible {
    case notWav(String), wrongFormat(String), noData(String), empty(URL)
    public var description: String {
        switch self {
        case .notWav(let f): "\(f): not a WAV file"
        case .wrongFormat(let f): "\(f): expected 16 kHz mono 16-bit"
        case .noData(let f): "\(f): no data chunk in the first 4 KB"
        case .empty(let u): "no recordings in \(u.path)"
        }
    }
}

enum Recording {
    static let nameFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Audio.timeZone
        return f
    }()

    /// (data offset, sample count). Ignores the header's size fields, which are
    /// wrong in a file cut short by a power loss; the file length is the truth.
    static func parseWav(_ url: URL) throws -> (offset: Int, count: Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = [UInt8](try handle.read(upToCount: 4096) ?? Data())
        let name = url.lastPathComponent
        guard head.count >= 12, head[0..<4].elementsEqual("RIFF".utf8), head[8..<12].elementsEqual("WAVE".utf8) else {
            throw RecordingError.notWav(name)
        }
        func u32(_ i: Int) -> Int { Int(head[i]) | Int(head[i + 1]) << 8 | Int(head[i + 2]) << 16 | Int(head[i + 3]) << 24 }
        func u16(_ i: Int) -> Int { Int(head[i]) | Int(head[i + 1]) << 8 }
        var i = 12
        var fmt: Int?
        while i + 8 <= head.count {
            let tag = String(decoding: head[i..<i + 4], as: UTF8.self), size = u32(i + 4)
            if tag == "fmt " { fmt = i + 8 }
            if tag == "data" {
                guard let f = fmt else { throw RecordingError.wrongFormat(name) }
                guard u16(f + 2) == 1, u32(f + 4) == Audio.sampleRate, u16(f + 14) == 16 else {
                    throw RecordingError.wrongFormat(name)
                }
                let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
                return (i + 8, (size - i - 8) / 2)
            }
            i += 8 + size + (size & 1)
        }
        throw RecordingError.noData(name)
    }

    static func segments(in dir: URL) throws -> [Segment] {
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var segments: [Segment] = []
        for url in files {
            guard let stamp = nameFormat.date(from: url.deletingPathExtension().lastPathComponent) else { continue }
            let (offset, count) = try parseWav(url)
            guard count >= Audio.window else { continue }
            var c = Chunk(url: url, wallStartMs: Int((stamp.timeIntervalSince1970 * 1000).rounded()),
                          dataOffset: offset, count: count)
            if var seg = segments.last, abs(c.wallStartMs - seg.endMs) <= Audio.contiguousToleranceMs {
                c.segmentOffset = seg.count
                seg.chunks.append(c)
                segments[segments.count - 1] = seg
            } else {
                segments.append(Segment(anchorMs: c.wallStartMs, chunks: [c]))
            }
        }
        guard !segments.isEmpty else { throw RecordingError.empty(dir) }
        return segments
    }
}
