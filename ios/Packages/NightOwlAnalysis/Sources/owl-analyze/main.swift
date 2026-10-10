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
let cpu = args.contains("--cpu")
args.removeAll { $0 == "--cpu" }
guard let path = args.first else {
    FileHandle.standardError.write("usage: owl-analyze NIGHT_DIR [--workers N] [--cpu] [--frames OUT.csv]\n".data(using: .utf8)!)
    exit(2)
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
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
print(String(decoding: try encoder.encode(result.report), as: UTF8.self))
