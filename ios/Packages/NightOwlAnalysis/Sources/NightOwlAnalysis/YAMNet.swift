import CoreML
import Foundation

/// The YAMNet Core ML model the Dream Catcher app and analyze.py both use.
/// One instance per worker: an MLModel isn't shared across threads here.
final class YAMNet {
    static let normPeak: Float = 0.5, normMaxGain: Float = 31.6   // same as YAMNetClassifier.swift

    /// The classes the report needs, in this order in every score row.
    static let watched = ["Snoring", "Speech", "Gasp"]
    enum Col { static let snoring = 0, speech = 1, gasp = 2 }

    private let model: MLModel
    private let indices: [Int]

    init(computeUnits: MLComputeUnits = .all) throws {
        guard let url = Bundle.module.url(forResource: "YAMNet", withExtension: "mlmodelc"),
              let map = Bundle.module.url(forResource: "yamnet_class_map", withExtension: "csv") else {
            throw AnalysisError.modelMissing
        }
        let names = try String(contentsOf: map, encoding: .utf8).split(whereSeparator: \.isNewline).dropFirst().map {
            // index,mid,display_name; names with commas are quoted
            let parts = $0.split(separator: ",", maxSplits: 2)
            return parts.count == 3 ? String(parts[2]).trimmingCharacters(in: CharacterSet(charactersIn: "\"\r")) : ""
        }
        indices = try Self.watched.map { w in
            guard let i = names.firstIndex(of: w) else { throw AnalysisError.classMissing(w) }
            return i
        }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: config)
    }

    /// One score row per window (each `classifierWindow` samples of hum-free audio).
    func scores(_ windows: [ArraySlice<Float>]) throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(windows.count)
        for start in stride(from: 0, to: windows.count, by: 256) {
            let batch = try windows[start..<min(start + 256, windows.count)].map { w -> MLFeatureProvider in
                let a = try MLMultiArray(shape: [NSNumber(value: Audio.classifierWindow)], dataType: .float32)
                var peak: Float = 0
                for v in w { peak = max(peak, abs(v)) }
                let gain = peak > 0 ? min(Self.normPeak / max(peak, 1e-12), Self.normMaxGain) : 1
                a.withUnsafeMutableBufferPointer(ofType: Float.self) { b, _ in
                    for (i, v) in w.enumerated() { b[i] = min(max(v * gain, -1), 1) }
                }
                return try MLDictionaryFeatureProvider(dictionary: ["waveform": MLFeatureValue(multiArray: a)])
            }
            let results = try model.predictions(fromBatch: MLArrayBatchProvider(array: batch))
            for k in 0..<results.count {
                guard let s = results.features(at: k).featureValue(for: "scores")?.multiArrayValue else {
                    throw AnalysisError.badOutput
                }
                out.append(indices.map { s[$0].floatValue })
            }
        }
        return out
    }
}
