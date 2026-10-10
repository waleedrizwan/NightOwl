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
