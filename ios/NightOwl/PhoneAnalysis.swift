import Foundation
import NightOwlAnalysis
import Security
import UIKit

/// "I'm up" without the Mac: stop the Pi, download the night from its file
/// server, analyze it here (NightOwlAnalysis, the Swift port of analyze.py),
/// and keep the result next to the nights the Mac publishes.
extension Store {
    struct Job: Equatable {
        var stage: String
        var fraction: Double?
    }

    // MARK: settings

    var piHost: String {
        get { access(keyPath: \.piHost); return UserDefaults.standard.string(forKey: "piHost") ?? PiClient.defaultHost }
        set { withMutation(keyPath: \.piHost) { UserDefaults.standard.set(newValue, forKey: "piHost") } }
    }

    var hasPi: Bool { piToken != nil }

    var pi: PiClient? { piToken.map { PiClient(host: piHost, token: $0) } }

    func setPi(host: String, token: String) {
        piHost = host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? PiClient.defaultHost : host.trimmingCharacters(in: .whitespacesAndNewlines)
        piToken = token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line for Settings: is the Pi there, and is it recording?
    func testPi() async -> String {
        guard let pi else { return "Paste the token first." }
        do {
            let s = try await pi.status()
            let nights = try await pi.nights()
            let gb = Double(nights.reduce(0) { $0 + $1.bytes }) / 1e9
            return "Connected. " + (s.recording ? "Recording now. " : "Not recording. ")
                + (nights.isEmpty ? "No nights waiting." : String(format: "%d night(s) waiting, %.1f GB.", nights.count, gb))
        } catch {
            return "\(error)"
        }
    }

    // MARK: the job

    /// Audio lives in Caches (iOS may purge it; it's re-downloadable) and only
    /// the newest night is kept, for clips.
    static var audioRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("nights")
    }

    @MainActor
    func analyzeOnPhone(stopFirst: Bool) async {
        guard let pi, job == nil else { return }
        job = Job(stage: stopFirst ? "Stopping the recorder" : "Connecting to the Pi")
        UIApplication.shared.isIdleTimerDisabled = true
        let background = UIApplication.shared.beginBackgroundTask(withName: "Analyze night")
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            UIApplication.shared.endBackgroundTask(background)
            job = nil
        }
        do {
            if stopFirst {
                try await pi.stop()
                wokeAt = .now
            }
            let today = Self.piDay.string(from: .now)
            let listings = try await pi.nights().filter { $0.completeBytes > 0 }
            guard let listing = (stopFirst ? listings.first { $0.night == today } : nil) ?? listings.last else {
                throw PhoneError.nothingOnPi
            }

            job = Job(stage: "Downloading from the Pi", fraction: 0)
            let dir = try await pi.download(listing, into: Self.audioRoot) { done, total in
                Task { @MainActor in
                    self.job?.stage = String(format: "Downloading from the Pi · %.0f of %.0f MB",
                                             Double(done) / 1e6, Double(total) / 1e6)
                    self.job?.fraction = Double(done) / Double(max(total, 1))
                }
            }
            Self.pruneAudio(keeping: listing.night)

            job = Job(stage: "Analyzing", fraction: 0)
            let result = try await Analyzer(workers: 2).analyze(night: dir) { stage, fraction in
                Task { @MainActor in self.job = Job(stage: stage, fraction: fraction) }
            }
            let night = try JSONDecoder().decode(Night.self, from: JSONEncoder().encode(result.report))
            savePhoneNight(night)
            error = nil
            openNight = night.dir
        } catch {
            self.error = "\(error)"
        }
    }

    private static func pruneAudio(keeping night: String) {
        let fm = FileManager.default
        for d in (try? fm.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: nil)) ?? []
        where d.lastPathComponent != night {
            try? fm.removeItem(at: d)
        }
    }

    /// The Pi names night folders by its local date (America/Toronto).
    static let piDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Audio.timeZone
        return f
    }()
}

enum PhoneError: Error, CustomStringConvertible {
    case nothingOnPi
    var description: String {
        switch self {
        case .nothingOnPi: "The Pi has no recordings waiting. Your Mac may have already copied last night; it will show up from there."
        }
    }
}

/// The Pi token, kept in the keychain rather than UserDefaults.
enum Keychain {
    private static let service = "com.waleedrizwan.NightOwl.pi"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    static func set(_ account: String, _ value: String?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let value else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
