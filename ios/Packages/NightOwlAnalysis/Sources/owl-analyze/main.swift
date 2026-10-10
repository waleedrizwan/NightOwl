import CoreML
import Foundation
import NightOwlAnalysis

// owl-analyze NIGHT_DIR [--workers N] [--cpu] [--frames OUT.csv]
// Runs the Swift analysis on a night folder and prints the night as the app
// reads it, to compare with the Mac's Python report.

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...i + 1) }
    return args[i + 1]
}
let workers = option("--workers").flatMap(Int.init) ?? 2
let framesOut = option("--frames")
let clipsOut = option("--clips")
let cpu = args.contains("--cpu"), wav = args.contains("--wav")
args.removeAll { $0 == "--cpu" || $0 == "--wav" }
guard var path = args.first else {
    FileHandle.standardError.write("""
        usage: owl-analyze NIGHT_DIR [--workers N] [--cpu] [--frames OUT.csv] [--clips DIR [--wav]]
               owl-analyze pi DOWNLOAD_DIR [NIGHT]   (token in $OWL_PI_TOKEN; downloads, then analyzes)

        """.data(using: .utf8)!)
    exit(2)
}
@Sendable func say(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

if path == "pi", args.count >= 2 {   // the phone's path: fetch from the Pi's file server first
    let pi = PiClient(token: ProcessInfo.processInfo.environment["OWL_PI_TOKEN"] ?? "")
    let status = try await pi.status()
    say("Pi: recording=\(status.recording) stoppedToday=\(status.stoppedToday)")
    let nights = try await pi.nights()
    guard let listing = args.count >= 3 ? nights.first(where: { $0.night == args[2] }) : nights.last else {
        say("no such night on the Pi (has: \(nights.map(\.night)))"); exit(1)
    }
    let t0 = Date()
    let last = Tally2()
    let dir = try await pi.download(listing, into: URL(fileURLWithPath: args[1])) { done, total in
        let pct = Int(100 * done / max(total, 1))
        if last.step(pct) { say("  downloaded \(pct)% of \(total / 1_000_000) MB") }
    }
    let secs = Date().timeIntervalSince(t0)
    say(String(format: "downloaded %@ (%.0f MB) in %.1f s = %.1f MB/s", listing.night,
               Double(listing.completeBytes) / 1e6, secs, Double(listing.completeBytes) / 1e6 / secs))
    path = dir.path
}

final class Tally2: @unchecked Sendable {
    private var last = -10
    private let lock = NSLock()
    func step(_ pct: Int) -> Bool { lock.lock(); defer { lock.unlock() }; if pct >= last + 10 { last = pct; return true }; return false }
}

let analyzer = Analyzer(workers: workers, computeUnits: cpu ? .cpuOnly : .all)
let result = try await analyzer.analyze(night: URL(fileURLWithPath: path))
FileHandle.standardError.write(String(format: "analyzed %d frames in %.1f s (%d workers%@)\n",
                                      result.frames.count, result.seconds, workers, cpu ? ", CPU only" : "").data(using: .utf8)!)
if let framesOut {
    var csv = "t_ms,rms_dbfs,peak_dbfs,noise_floor_dbfs,snoring,speech,gasp\n"
    for f in result.frames {
        csv += String(format: "%ld,%.4f,%.4f,%.4f,%.6f,%.6f,%.6f\n", f.tMs, f.rmsDbfs, f.peakDbfs, f.noiseFloor,
                      f.snoring, f.speech, f.gasp)
    }
    try csv.write(toFile: framesOut, atomically: true, encoding: .utf8)
}
var report = result.report
if let clipsOut {
    let t0 = Date()
    report = try Clips.write(result, into: URL(fileURLWithPath: clipsOut), prefix: "clips/", format: wav ? .wav : .aac)
    say(String(format: "wrote %d clips in %.1f s", report.bouts.count + report.gasps.count, Date().timeIntervalSince(t0)))
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
print(String(decoding: try encoder.encode(report), as: UTF8.self))
