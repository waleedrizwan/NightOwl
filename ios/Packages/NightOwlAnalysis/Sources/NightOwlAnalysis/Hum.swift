import Accelerate
import Foundation

/// Steady tones (mains hum, fans, the capture chain's digital lines) and their
/// removal: denoise.py find_tones / night_tones / merge_tones / remove_hum.
public enum Hum {
    static let baseHz = 60.0, maxHz = 1500.0, notchSigmaHz = 0.75
    static let highpassLoHz = 25.0, highpassHiHz = 45.0
    static let digitalDivisor = 256.0, digitalMaxHz = 1000.0, digitalSigmaHz = 0.4
    static let toneProminenceDb = 7.0, toneMinHz = 25.0, toneMaxHz = 7800.0, toneSigmaHz = 0.6
    static let toneMaxCount = 60
    static let welchN = 262_144          // 16.4 s segments: 0.06 Hz resolution
    static let padSeconds = 1.0

    /// Frequencies (Hz) of steady narrowband lines in x, strongest first.
    public static func findTones(_ input: [Double], sampleRate sr: Double = 16_000) -> [Double] {
        let mean = vDSP.mean(input)
        let x = vDSP.add(-mean, input)
        var n = welchN
        while n > 4096 && x.count < 4 * n { n /= 2 }
        guard x.count >= n else { return [] }
        let fft = RealFFT(count: n)
        let window = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1)) }   // np.hanning
        var power = [Double](repeating: 0, count: n / 2 + 1)
        var segments = 0
        var seg = [Double](repeating: 0, count: n)
        for start in stride(from: 0, through: x.count - n, by: n / 2) {
            x.withUnsafeBufferPointer { xb in
                vDSP.multiply(UnsafeBufferPointer(rebasing: xb[start..<start + n]), window, result: &seg)
            }
            fft.addPower(of: seg, into: &power)
            segments += 1
        }
        let df = sr / Double(n)
        let L = power.map { 10 * log10($0 / Double(segments) + 1e-30) }
        let half = max(2, Int((10.0 / df).rounded(.toNearestOrEven)))
        var tones: [(i: Int, prom: Double)] = []
        if L.count > 4 {
            for i in 2..<(L.count - 2) {
                guard L[i] >= L[i - 1], L[i] >= L[i + 1], L[i] >= L[i - 2], L[i] >= L[i + 2] else { continue }
                let f = Double(i) * df
                guard f >= toneMinHz, f <= toneMaxHz else { continue }
                var w = (i - half...i + half).map { L[min(max($0, 0), L.count - 1)] }
                w.sort()
                let prom = L[i] - w[half]
                if prom >= toneProminenceDb { tones.append((i, prom)) }
            }
        }
        tones.sort { $0.prom > $1.prom }
        return tones.prefix(toneMaxCount).map { t in   // parabolic interpolation for a sub-bin frequency
            let a = L[t.i - 1], b = L[t.i], c = L[t.i + 1]
            let den = a - 2 * b + c
            let d = den != 0 ? 0.5 * (a - c) / den : 0
            return (Double(t.i) + d) * df
        }
    }

    /// Tones found in at least minShare of the night's files (and at least two).
    public static func nightTones(_ perFile: [[Double]], minShare: Double = 0.1, tolHz: Double = 0.25) -> [Double] {
        var found: [(Double, Int)] = []
        for (i, ts) in perFile.enumerated() { for t in ts { found.append((t, i)) } }
        found.sort { (a: (Double, Int), b: (Double, Int)) -> Bool in a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }
        let need = max(2, Int((minShare * Double(perFile.count)).rounded(.up)))
        var out: [Double] = [], group: [(Double, Int)] = []
        for (t, i) in found + [(Double.infinity, -1)] {
            if let last = group.last, t - last.0 > tolHz {
                if Set(group.map(\.1)).count >= need { out.append(median(group.map(\.0))) }
                group = []
            }
            group.append((t, i))
        }
        return out
    }

    public static func mergeTones(_ lists: [Double]...) -> [Double] {
        var out: [Double] = []
        for t in lists.flatMap({ $0 }).sorted() where out.last.map({ t - $0 > 0.2 }) ?? true {
            out.append(t)
        }
        return out
    }

    /// High-pass + 60 Hz family + the capture chain's digital lines + every
    /// steady tone, zero phase. Same length as x.
    ///
    /// Differs from denoise.py only in padding: 1 s of reflection each side as
    /// there, then zeros up to a power of two (Accelerate's real FFT size)
    /// instead of more reflection up to a 2·3·5-smooth size.
    public static func removeHum(_ x: [Double], sampleRate sr: Double = 16_000, tones: [Double]) -> [Float] {
        let pad = min(Int(padSeconds * sr), x.count - 1)
        let used = x.count + 2 * pad
        var n = 1
        while n < used { n <<= 1 }
        let fft = RealFFT(count: n)
        return fft.filter(keeping: pad..<pad + x.count, fill: { i in
            if i < pad { return x[pad - i] }                       // numpy "reflect": edge sample not repeated
            if i < pad + x.count { return x[i - pad] }
            if i < used { return x[2 * x.count - 2 - (i - pad)] }
            return 0
        }, gain: { spectrum in
            let df = sr / Double(n)
            // raised-cosine high-pass: 0 below 25 Hz, 1 above 45 Hz
            for k in 0...Int(highpassHiHz / df) + 1 {
                let r = min(max((Double(k) * df - highpassLoHz) / (highpassHiHz - highpassLoHz), 0), 1)
                spectrum.scale(bin: k, by: 0.5 - 0.5 * cos(Double.pi * r))
            }
            var notches = (1...Int(maxHz / baseHz)).map { (Double($0) * baseHz, notchSigmaHz) }
            let base = sr / digitalDivisor
            notches += (1...Int(digitalMaxHz / base)).map { (Double($0) * base, digitalSigmaHz) }
            notches += tones.map { ($0, toneSigmaHz) }
            for (centre, sigma) in notches {
                let lo = Int(((centre - 6 * sigma) / df).rounded(.up)), hi = Int(((centre + 6 * sigma) / df).rounded(.up))
                for k in max(lo, 0)..<min(hi, n / 2 + 1) {
                    let z = (Double(k) * df - centre) / sigma
                    spectrum.scale(bin: k, by: 1 - exp(-0.5 * z * z))
                }
            }
        })
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted(), m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }
}

/// Real FFT of a power-of-two length in numpy's conventions (unscaled forward,
/// irfft divides by n), over Accelerate's packed split-complex format.
final class RealFFT {
    let count: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetupD

    init(count: Int) {
        precondition(count > 0 && count & (count - 1) == 0, "power of two")
        self.count = count
        log2n = vDSP_Length(count.trailingZeroBitCount)
        setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetupD(setup) }

    /// power[k] += |X[k]|² for k in 0...n/2.
    func addPower(of x: [Double], into power: inout [Double]) {
        let h = count / 2
        var re = [Double](repeating: 0, count: h), im = [Double](repeating: 0, count: h)
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                x.withUnsafeBytes { xb in
                    vDSP_ctozD(xb.bindMemory(to: DSPDoubleComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(h))
                }
                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        // vDSP's forward real FFT is 2x numpy's; bin 0 holds DC (real) and Nyquist (imag)
        power[0] += (re[0] / 2) * (re[0] / 2)
        power[h] += (im[0] / 2) * (im[0] / 2)
        for k in 1..<h { power[k] += (re[k] * re[k] + im[k] * im[k]) / 4 }
    }

    struct Spectrum {
        let re: UnsafeMutablePointer<Double>, im: UnsafeMutablePointer<Double>, half: Int
        /// Multiply bin k (0...n/2) by a real gain.
        func scale(bin k: Int, by g: Double) {
            if k == 0 { re[0] *= g } else if k == half { im[0] *= g } else { re[k] *= g; im[k] *= g }
        }
    }

    /// irfft(rfft(signal) * gain)[keep] as Float, signal[i] = fill(i) for i < n.
    /// Works in place in the two half-length arrays: no full-length copies,
    /// which matters on the phone (n is 2^24 for a 10-minute file).
    func filter(keeping keep: Range<Int>, fill: (Int) -> Double, gain: (Spectrum) -> Void) -> [Float] {
        let n = count, h = n / 2
        var re = [Double](unsafeUninitializedCapacity: h) { b, c in for k in 0..<h { b[k] = fill(2 * k) }; c = h }
        var im = [Double](unsafeUninitializedCapacity: h) { b, c in for k in 0..<h { b[k] = fill(2 * k + 1) }; c = h }
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                gain(Spectrum(re: r.baseAddress!, im: i.baseAddress!, half: h))
                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
            }
        }
        // forward is 2x numpy, inverse is n/2 x numpy's irfft: undo both.
        // Sample j sits in re[j/2] (even j) or im[j/2] (odd j).
        let scale = 1 / Double(2 * n)
        return [Float](unsafeUninitializedCapacity: keep.count) { b, c in
            for (o, j) in keep.enumerated() { b[o] = Float((j & 1 == 0 ? re[j >> 1] : im[j >> 1]) * scale) }
            c = keep.count
        }
    }
}
