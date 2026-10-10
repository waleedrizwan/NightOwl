import Accelerate
import Foundation

/// The mic's steady hiss, measured and gated out for listening (denoise.py
/// noise_profile / denoise / boost). Per frequency bin:
///
///     noise[f]   = 20th percentile of |STFT| over time (breaths are brief; hiss is always there)
///     mask[t, f] = soft step from 0 to 1 as |STFT| rises from 1.5x to 3x noise[f]
///
/// The mask is smoothed over 3 frames and 5 bins and floored at -24 dB.
/// Detection never uses this: it's only for the clips.
///
/// Both run frame by frame (a 1024-sample window every 256 samples), so a long
/// clip needs no full-length spectrogram: a 33-minute bout would otherwise
/// take ~500 MB.
public enum Denoise {
    static let nFFT = 1024, hop = 256
    static let bins = nFFT / 2 + 1
    static let noisePercentile = 20.0
    static let gateLo: Float = 1.5, gateHi: Float = 3.0
    static let floor = Float(pow(10.0, -24.0 / 20))

    /// np.hanning(1025)[:-1]: the periodic Hann window.
    static let window: [Float] = (0..<nFFT).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nFFT))) }

    /// Hiss profile of a stretch of audio (a whole 10-minute file, so a clip
    /// full of snoring is not mistaken for noise).
    public static func noiseProfile(_ x: [Float]) -> [Float] {
        let frames = Frames(x)
        let T = frames.count
        var byFrame = [Float](repeating: 0, count: bins * T)     // one row per frame, written in order
        frames.forEach { t, re, im in
            for k in 0..<bins { byFrame[t * bins + k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() }
        }
        var byBin = [Float](repeating: 0, count: bins * T)       // one row per bin
        vDSP_mtrans(byFrame, 1, &byBin, 1, vDSP_Length(bins), vDSP_Length(T))
        byFrame = []
        // numpy's default (linear) percentile needs just two order statistics per bin
        let pos = noisePercentile / 100 * Double(T - 1)
        let lo = Int(pos), frac = Float(pos - Double(lo))
        return byBin.withUnsafeMutableBufferPointer { b in
            (0..<bins).map { k in
                let row = UnsafeMutableBufferPointer(rebasing: b[(k * T)..<((k + 1) * T)])
                let a = select(row, lo)
                guard lo + 1 < T else { return a }
                let next = row[(lo + 1)...].min()!      // after select, everything right of lo is >= it
                return a + frac * (next - a)
            }
        }
    }

    /// The k-th smallest value (quickselect); leaves smaller values before k, larger after.
    static func select(_ v: UnsafeMutableBufferPointer<Float>, _ k: Int) -> Float {
        var lo = 0, hi = v.count - 1
        while lo < hi {
            let pivot = v[(lo + hi) / 2]
            var i = lo, j = hi
            while i <= j {
                while v[i] < pivot { i += 1 }
                while v[j] > pivot { j -= 1 }
                if i <= j { v.swapAt(i, j); i += 1; j -= 1 }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { return v[k] }
        }
        return v[k]
    }

    /// Hiss removed from x, same length.
    public static func denoise(_ x: [Float], profile: [Float]) -> [Float] {
        let frames = Frames(x)
        let T = frames.count
        let inverse = FFT1024()
        let outLen = hop * (T - 1) + nFFT
        var out = [Float](repeating: 0, count: outLen)
        let noise = profile.map { max($0, 1e-12) }

        func rawMask(_ re: [Float], _ im: [Float]) -> [Float] {
            (0..<bins).map { k in
                let ratio = (re[k] * re[k] + im[k] * im[k]).squareRoot() / noise[k]
                return min(max((ratio - gateLo) / (gateHi - gateLo), 0), 1)
            }
        }

        // Frame t is finished once frame t+1's raw mask is known (3-frame time smoothing).
        var ring: [(re: [Float], im: [Float], mask: [Float])] = []   // frames t-1, t, t+1
        var next = 0
        func finish(_ t: Int, _ before: [Float], _ cur: (re: [Float], im: [Float], mask: [Float]), _ after: [Float]) {
            var s = [Float](repeating: 0, count: bins)
            for k in 0..<bins { s[k] = (before[k] + cur.mask[k] + after[k]) / 3 }
            var re = cur.re, im = cur.im
            for k in 0..<bins {
                var sum: Float = 0
                for d in -2...2 { sum += s[min(max(k + d, 0), bins - 1)] }
                let g = max(sum / 5, floor)
                re[k] *= g; im[k] *= g
            }
            let y = inverse.inverse(re, im)
            for i in 0..<nFFT { out[t * hop + i] += y[i] * window[i] }
        }
        frames.forEach { t, re, im in
            ring.append((re, im, rawMask(re, im)))
            if ring.count == 2, next == 0 {          // first frame: its "before" is itself (edge padding)
                finish(0, ring[0].mask, ring[0], ring[1].mask)
                next = 1
            } else if ring.count == 3 {
                finish(next, ring[0].mask, ring[1], ring[2].mask)
                next += 1
                ring.removeFirst()
            }
        }
        if T == 1 {
            finish(0, ring[0].mask, ring[0], ring[0].mask)
        } else {                                     // last frame: its "after" is itself
            finish(T - 1, ring[ring.count - 2].mask, ring[ring.count - 1], ring[ring.count - 1].mask)
        }

        // divide by the summed squared windows, then drop the padding
        let w2 = window.map { $0 * $0 }
        let start = nFFT / 2
        return (0..<x.count).map { j in
            let i = start + j
            var norm: Float = 0
            var t = max(0, (i - nFFT) / hop)
            while t < T, t * hop <= i {
                let o = i - t * hop
                if o < nFFT { norm += w2[o] }
                t += 1
            }
            return out[i] / max(norm, 1e-8)
        }
    }

    /// Turn up for listening: the 99.9th-percentile sample to target.
    public static func boost(_ x: [Float], target: Float = 0.5) -> [Float] {
        guard !x.isEmpty else { return x }
        var a = x.map(abs)
        vDSP_vsort(&a, vDSP_Length(a.count), 1)
        let pos = 0.999 * Double(a.count - 1)
        let lo = Int(pos), frac = Float(pos - Double(lo))
        let ref = lo + 1 < a.count ? a[lo] + frac * (a[lo + 1] - a[lo]) : a[lo]
        return ref > 0 ? vDSP.multiply(target / ref, x) : x
    }

    /// The STFT frames of (x − mean), padded like denoise.py's _stft:
    /// 512 reflected samples before, 512 + 256 after.
    struct Frames {
        let count: Int
        private let x: [Float], mean: Float

        init(_ x: [Float]) {
            self.x = x
            mean = Float(x.reduce(0.0) { $0 + Double($1) } / Double(max(x.count, 1)))
            count = 1 + (x.count + Denoise.nFFT + Denoise.hop - Denoise.nFFT) / Denoise.hop
        }

        private func padded(_ i: Int) -> Float {
            let pre = Denoise.nFFT / 2
            var j = i - pre
            if j < 0 { j = -j }                               // numpy "reflect"
            if j >= x.count { j = 2 * (x.count - 1) - j }
            return x[min(max(j, 0), x.count - 1)] - mean
        }

        /// body(t, re, im) with numpy-scaled rfft bins 0...512 of frame t.
        func forEach(_ body: (Int, [Float], [Float]) -> Void) {
            let fft = FFT1024()
            var frame = [Float](repeating: 0, count: Denoise.nFFT)
            for t in 0..<count {
                for i in 0..<Denoise.nFFT { frame[i] = padded(t * Denoise.hop + i) * Denoise.window[i] }
                let (re, im) = fft.forward(frame)
                body(t, re, im)
            }
        }
    }
}

/// 1024-point real FFT in numpy's scaling, bins 0...512 unpacked.
final class FFT1024 {
    private let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
    private var re = [Float](repeating: 0, count: 512), im = [Float](repeating: 0, count: 512)
    deinit { vDSP_destroy_fftsetup(setup) }

    func forward(_ x: [Float]) -> ([Float], [Float]) {
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var s = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                x.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &s, 1, 512) }
                vDSP_fft_zrip(setup, &s, 1, 10, FFTDirection(kFFTDirection_Forward))
            }
        }
        var outRe = [Float](repeating: 0, count: 513), outIm = [Float](repeating: 0, count: 513)
        outRe[0] = re[0] / 2; outRe[512] = im[0] / 2           // DC and Nyquist are packed in bin 0
        for k in 1..<512 { outRe[k] = re[k] / 2; outIm[k] = im[k] / 2 }
        return (outRe, outIm)
    }

    /// irfft of bins 0...512 (numpy scaling: divides by n).
    func inverse(_ inRe: [Float], _ inIm: [Float]) -> [Float] {
        re[0] = inRe[0]; im[0] = inRe[512]
        for k in 1..<512 { re[k] = inRe[k]; im[k] = inIm[k] }
        var out = [Float](repeating: 0, count: 1024)
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var s = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zrip(setup, &s, 1, 10, FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBytes { vDSP_ztoc(&s, 1, $0.bindMemory(to: DSPComplex.self).baseAddress!, 2, 512) }
            }
        }
        // vDSP's forward is 2x numpy and a round trip is 2n x: from numpy-scaled bins, divide by n
        return vDSP.multiply(1 / Float(1024), out)
    }
}
