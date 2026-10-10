import XCTest
@testable import NightOwlAnalysis

final class HumTests: XCTestCase {
    /// A flat gain must give the signal back: checks the FFT scaling and packing.
    func testFilterWithUnitGainIsIdentity() {
        let n = 4096
        let x = (0..<n).map { sin(Double($0) * 0.37) + 0.2 * cos(Double($0) * 1.9) + 0.05 }
        let y = RealFFT(count: n).filter(keeping: 0..<n, fill: { x[$0] }, gain: { _ in })
        XCTAssertEqual(zip(x, y).map { abs($0 - Double($1)) }.max()!, 0, accuracy: 1e-6)   // Float output
    }

    /// The hum removal takes out a strong 60 Hz line and a found tone and keeps speech-band sound.
    func testRemoveHumNotchesTonesKeepsTheRest() {
        let sr = 16_000.0
        let n = 16_000 * 30
        let x = (0..<n).map { i -> Double in
            let t = Double(i) / sr
            return 0.3 * sin(2 * .pi * 60 * t) + 0.2 * sin(2 * .pi * 55.6 * t) + 0.1 * sin(2 * .pi * 440 * t)
        }
        let tones = Hum.findTones(x)
        XCTAssertTrue(tones.contains { abs($0 - 55.6) < 0.1 }, "found \(tones.prefix(5))")
        XCTAssertTrue(tones.contains { abs($0 - 440) < 0.1 }, "a steady sine is a tone too")
        // remove only the 55.6 Hz line (plus the built-in 60 Hz family): 440 Hz must survive
        let y = Hum.removeHum(x, tones: tones.filter { abs($0 - 440) > 1 }).map(Double.init)
        let mid = (n / 3)..<(2 * n / 3)
        func amplitude(_ s: [Double], _ hz: Double) -> Double {
            var c = 0.0, d = 0.0
            for i in mid { let p = 2 * Double.pi * hz * Double(i) / sr; c += s[i] * cos(p); d += s[i] * sin(p) }
            return 2 * (c * c + d * d).squareRoot() / Double(mid.count)
        }
        XCTAssertLessThan(amplitude(y, 60), 0.003)
        XCTAssertLessThan(amplitude(y, 55.6), 0.003)
        XCTAssertEqual(amplitude(y, 440), 0.1, accuracy: 0.002)
    }

    func testScoreMatchesScorePy() {
        // 2026-10-10: 2,746,000 ms of snoring in 33,527,875 ms recorded, 6 gasps → 31
        XCTAssertEqual(NightReport.snoreScore(recordedMs: 33_527_875, snoreMs: 2_746_000, gasps: 6), 31)
        XCTAssertEqual(NightReport.band(31), "moderate")
        XCTAssertEqual(NightReport.band(9), "quiet")
    }
}

final class DenoiseTests: XCTestCase {
    /// With a zero hiss profile every bin is far above it, the mask is 1, and
    /// the STFT round trip must give back the signal minus its mean.
    func testZeroProfileGivesTheSignalBack() {
        let x: [Float] = (0..<20_000).map { Float(sin(Double($0) * 0.05) * 0.3 + 0.01) }
        let y = Denoise.denoise(x, profile: [Float](repeating: 0, count: 513))
        let mean = x.reduce(0, +) / Float(x.count)
        XCTAssertEqual(y.count, x.count)
        XCTAssertEqual(zip(x, y).map { abs($0 - mean - $1) }.max()!, 0, accuracy: 1e-4)
    }

    /// White noise measured as its own hiss is turned down to ~0.45x, as denoise.py
    /// does (0.448 on the same kind of signal): its 20th-percentile profile sits
    /// below most bins' peaks, so many are only partly gated.
    func testHissAtTheProfileIsSuppressed() {
        var g = SystemRandomNumberGenerator()
        let x: [Float] = (0..<64_000).map { _ in Float.random(in: -0.01...0.01, using: &g) }
        let y = Denoise.denoise(x, profile: Denoise.noiseProfile(x))
        func rms(_ v: [Float]) -> Float { (v.map { $0 * $0 }.reduce(0, +) / Float(v.count)).squareRoot() }
        XCTAssertEqual(rms(Array(y[8_000..<56_000])) / rms(Array(x[8_000..<56_000])), 0.448, accuracy: 0.02)
    }
}
