import BackgroundTasks
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
    /// the newest night is kept, to remake its clips if needed.
    static var audioRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("nights")
    }

    /// Clips made here: Application Support/phone-clips/<night>/*.m4a, referred
    /// to in the night as "phone-clips/<night>/<name>" (the Mac's are "clips/…" in iCloud).
    static let phoneClipsPrefix = "phone-clips/"
    static var phoneClipsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("phone-clips")
    }

    /// Stop (optionally), download, analyze and make clips. On iOS 26 this runs
    /// as a continued-processing task, so it carries on with the screen locked
    /// or another app open, with the system's own progress UI; otherwise (or if
    /// the system won't start one) it runs here and needs the app kept open.
    @MainActor
    func analyzeOnPhone(stopFirst: Bool) async {
        guard pi != nil, job == nil else { return }
        job = Job(stage: stopFirst ? "Stopping the recorder" : "Connecting to the Pi")
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            job = nil
        }
        if #available(iOS 26, *),
           await ContinuedJob.run(title: "Night Owl", subtitle: job?.stage ?? "", work: { report in
               await self.runJob(stopFirst: stopFirst, report: report)
           }) {
            return
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "Analyze night")
        defer { UIApplication.shared.endBackgroundTask(background) }
        _ = await runJob(stopFirst: stopFirst) { _, _ in }
    }

    /// The job itself. report(stage, overall 0...1) feeds the system's progress UI.
    @MainActor
    private func runJob(stopFirst: Bool, report: @escaping @MainActor (String, Double) -> Void) async -> Bool {
        guard let pi else { return false }
        func set(_ stage: String, _ fraction: Double?, overall: Double) {
            job = Job(stage: stage, fraction: fraction)
            report(stage, overall)
        }
        do {
            if stopFirst {
                set("Stopping the recorder", nil, overall: 0.01)
                try await pi.stop()
                wokeAt = .now
            }
            let today = Self.piDay.string(from: .now)
            let listings = try await pi.nights().filter { $0.completeBytes > 0 }
            guard let listing = (stopFirst ? listings.first { $0.night == today } : nil) ?? listings.last else {
                throw PhoneError.nothingOnPi
            }

            set("Downloading from the Pi", 0, overall: 0.02)
            let dir = try await pi.download(listing, into: Self.audioRoot) { done, total in
                let f = Double(done) / Double(max(total, 1))
                Task { @MainActor in
                    set(String(format: "Downloading from the Pi · %.0f of %.0f MB", Double(done) / 1e6, Double(total) / 1e6),
                        f, overall: 0.02 + 0.38 * f)
                }
            }
            Self.pruneAudio(keeping: listing.night)

            set("Analyzing", 0, overall: 0.40)
            // CPU only: the GPU isn't available to background work without a special
            // entitlement, and it only saved ~5 s a night (benchmark, iPhone 17)
            let result = try await Analyzer(workers: 2, computeUnits: .cpuOnly).analyze(night: dir) { stage, f in
                Task { @MainActor in set(stage, f, overall: 0.40 + 0.48 * f) }
            }
            set("Making clips", 0, overall: 0.88)
            let withClips = try await Task.detached(priority: .userInitiated) {
                try Clips.write(result, into: Self.phoneClipsRoot.appendingPathComponent(listing.night),
                                prefix: "\(Self.phoneClipsPrefix)\(listing.night)/") { f in
                    Task { @MainActor in set("Making clips", f, overall: 0.88 + 0.12 * f) }
                }
            }.value
            let night = try JSONDecoder().decode(Night.self, from: JSONEncoder().encode(withClips))
            savePhoneNight(night)
            error = nil
            openNight = night.dir
            report("Report ready", 1)
            return true
        } catch is CancellationError {
            error = "iOS stopped the analysis before it finished (the phone may have been too busy or too warm). Tap it again to pick up where it left off: downloaded files are kept."
            return false
        } catch {
            self.error = "\(error)"
            return false
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

/// One run of the job as an iOS 26 continued-processing task: the system keeps
/// it going with the app in the background and shows its progress.
@available(iOS 26, *)
enum ContinuedJob {
    /// Info.plist BGTaskSchedulerPermittedIdentifiers has "<this>.*".
    static let prefix = "com.waleedrizwan.NightOwl.analyze"

    /// Runs work inside a BGContinuedProcessingTask and returns true once it has
    /// finished (well or not). Returns false without running it if the system
    /// won't start one right now; then run it in the foreground instead.
    @MainActor
    static func run(title: String, subtitle: String,
                    work: @escaping @MainActor (_ report: @escaping @MainActor (String, Double) -> Void) async -> Bool) async -> Bool {
        // a fresh identifier each time: each may be registered only once
        let id = "\(prefix).\(UUID().uuidString.prefix(8))"
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                task.progress.totalUnitCount = 1000
                let running = Task { @MainActor in
                    let ok = await work { stage, overall in
                        task.updateTitle(title, subtitle: stage)
                        task.progress.completedUnitCount = Int64(min(max(overall, 0), 1) * 1000)
                    }
                    task.setTaskCompleted(success: ok)
                    done.resume(returning: true)
                }
                task.expirationHandler = { running.cancel() }
            }
            guard registered else { done.resume(returning: false); return }
            let request = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: subtitle)
            request.strategy = .fail          // run now or not at all; we fall back to the foreground
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                print("continued processing refused: \(error)")
                done.resume(returning: false)
            }
        }
    }
}
