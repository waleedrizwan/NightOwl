import BackgroundTasks
import Foundation
import NightOwlAnalysis
import Security
import UIKit
import UserNotifications

/// "I'm up" without the Mac: stop the Pi, download the night from its file
/// server, analyze it here (NightOwlAnalysis, the Swift port of analyze.py),
/// and keep the result next to the nights the Mac publishes.
extension Store {
    struct Job: Equatable {
        var step = 1                  // of Job.steps
        var stage: String
        var overall = 0.0             // 0...1 across the whole job
        var started = Date.now
        var lastProgress = Date.now   // for "no progress for a while"
        var inBackground = false      // running as a continued-processing task (survives a locked screen)
        static let steps = 4          // stop + download, find hums, listen, clips
    }

    // MARK: recording (the Pi's schedule and "Start recording")

    static let defaultSchedule = PiClient.Schedule(auto: true, start: "02:00", end: "11:00")

    /// The last schedule the Pi reported, for guessing while it's out of reach.
    static var cachedSchedule: PiClient.Schedule {
        get {
            (UserDefaults.standard.data(forKey: "piSchedule")).flatMap { try? JSONDecoder().decode(PiClient.Schedule.self, from: $0) }
                ?? defaultSchedule
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "piSchedule") }
    }

    /// Ask the Pi what it's doing. On failure the app falls back to the schedule.
    @MainActor
    func refreshPiStatus() async {
        guard let pi else { piStatus = nil; return }
        let s = try? await pi.status()
        if s != piStatus { piStatus = s }
        if let schedule = s?.schedule { Self.cachedSchedule = schedule }
    }

    /// "HH:MM" the current or next recording stops at.
    var stopTime: String {
        if let until = piStatus?.manualUntil {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            f.timeZone = Audio.timeZone
            return f.string(from: Date(ms: until))
        }
        return (piStatus?.schedule ?? Self.cachedSchedule).end
    }

    @MainActor
    func startRecording() async {
        guard let pi else { return }
        do {
            piStatus = try await pi.start()
            if piStatus?.recording != true {
                error = "The Pi didn't start recording. Is the microphone plugged in?"
            } else {
                error = nil
            }
        } catch {
            self.error = "\(error)"
        }
    }

    /// Saves the schedule on the Pi; returns a line for Settings.
    @MainActor
    func saveSchedule(_ schedule: PiClient.Schedule) async -> String {
        guard let pi else { return "Set up the Pi first." }
        do {
            piStatus = try await pi.setSchedule(schedule)
            Self.cachedSchedule = piStatus?.schedule ?? schedule
            return schedule.auto ? "Saved. The Pi records every night \(schedule.start)–\(schedule.end)."
                : "Saved. The Pi only records when you tap Start recording."
        } catch {
            return "\(error)"
        }
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
               self.job?.inBackground = true
               return await self.runJob(stopFirst: stopFirst, report: report)
           }) {
            return
        }
        JobLog.write("running in the foreground only")
        final class Slot: @unchecked Sendable { var id = UIBackgroundTaskIdentifier.invalid }
        let background = Slot()
        func endBackground() {
            guard background.id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(background.id)
            background.id = .invalid
        }
        background.id = UIApplication.shared.beginBackgroundTask(withName: "Analyze night") {
            JobLog.write("foreground-only run: out of background time, iOS is suspending the app")
            MainActor.assumeIsolated { endBackground() }
        }
        defer { endBackground() }
        _ = await runJob(stopFirst: stopFirst) { _, _ in }
    }

    /// The job itself. report(stage, overall 0...1) feeds the system's progress UI.
    @MainActor
    private func runJob(stopFirst: Bool, report: @escaping @MainActor (String, Double) -> Void) async -> Bool {
        guard let pi else { return false }
        func set(_ step: Int, _ stage: String, overall: Double) {
            guard var j = job else { return }
            if j.stage != stage || abs(j.overall - overall) >= 0.001 { j.lastProgress = .now }
            j.step = step
            j.stage = stage
            j.overall = max(j.overall, overall)
            job = j
            report(stage, overall)
        }
        do {
            if stopFirst {
                set(1, "Stopping the recorder", overall: 0.01)
                try await pi.stop()
                wokeAt = .now
            }
            let today = Self.piDay.string(from: .now)
            let listings = try await pi.nights().filter { $0.completeBytes > 0 }
            guard let listing = (stopFirst ? listings.first { $0.night == today } : nil) ?? listings.last else {
                throw PhoneError.nothingOnPi
            }

            set(1, "Downloading last night from the Pi", overall: 0.02)
            let dir = try await pi.download(listing, into: Self.audioRoot, waiting: { lost in
                Task { @MainActor in
                    JobLog.write(lost ? "lost the Pi mid-download; waiting" : "Pi back")
                    if lost { set(1, "Lost the Pi for a moment, waiting for it to come back", overall: self.job?.overall ?? 0.02) }
                }
            }) { done, total in
                let f = Double(done) / Double(max(total, 1))
                Task { @MainActor in
                    set(1, String(format: "Downloading last night from the Pi · %.0f of %.0f MB", Double(done) / 1e6, Double(total) / 1e6),
                        overall: 0.02 + 0.28 * f)
                }
            }
            Self.pruneAudio(keeping: listing.night)

            set(2, "Finding steady hums", overall: 0.30)
            // CPU only: the GPU isn't available to background work without a special
            // entitlement, and it only saved ~5 s a night (benchmark, iPhone 17)
            let result = try await Analyzer(workers: 2, computeUnits: .cpuOnly).analyze(night: dir) { stage, f in
                Task { @MainActor in set(f < 0.15 ? 2 : 3, stage, overall: 0.30 + 0.60 * f) }
            }
            set(4, "Making clips to listen to", overall: 0.90)
            let withClips = try await Task.detached(priority: .userInitiated) {
                try Clips.write(result, into: Self.phoneClipsRoot.appendingPathComponent(listing.night),
                                prefix: "\(Self.phoneClipsPrefix)\(listing.night)/") { f in
                    Task { @MainActor in set(4, "Making clips to listen to", overall: 0.90 + 0.10 * f) }
                }
            }.value
            let night = try JSONDecoder().decode(Night.self, from: JSONEncoder().encode(withClips))
            savePhoneNight(night)
            error = nil
            openNight = night.dir
            report("Report ready", 1)
            JobLog.write("done: \(night.dir) in \(Int(Date.now.timeIntervalSince(job?.started ?? .now)))s")
            Self.notify(title: "Snore Score \(night.score) · \(night.band)",
                        body: (night.snoreMs > 0 ? "\(Self.hm(night.snoreMs)) snoring" : "No snoring")
                            + " (\(night.percentOfNight)% of \(Self.hm(night.recordedMs)))"
                            + (night.gasps.isEmpty ? "" : " · \(night.gasps.count) possible gasp\(night.gasps.count > 1 ? "s" : "")"),
                        night: night.dir)
            return true
        } catch is CancellationError {
            JobLog.write("cancelled at \(job?.stage ?? "?")")
            error = "iOS stopped the analysis before it finished (the phone may have been too busy or too warm). Tap it again to pick up where it left off: downloaded files are kept."
            Self.notify(title: "Last night's report didn't finish", body: "Open Night Owl and tap I'm up to pick up where it left off.")
            return false
        } catch {
            JobLog.write("failed at \(job?.stage ?? "?"): \(error)")
            self.error = "\(error)"
            Self.notify(title: "Last night's report didn't finish", body: "\(error)")
            return false
        }
    }

    /// A local notification when the job ends, unless the app is on screen
    /// (then the report or the error is already in front of you). Tapping it
    /// opens the night, like the Mac's push.
    @MainActor
    private static func notify(title: String, body: String, night: String? = nil) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let night { content.userInfo = ["night": night] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "phone-job", content: content, trigger: nil))
    }

    /// "1h 23m" / "23m"
    static func hm(_ ms: Int) -> String {
        let m = ms / 60_000
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
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

/// What iOS did with each "I'm up" run (background allowed or refused, started,
/// expired, how it ended), in Application Support/job-log.txt for reading off
/// the phone later: `devicectl device copy from`.
enum JobLog {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("job-log.txt")
    }

    static func write(_ line: String) {
        print("[job] \(line)")
        let stamped = "\(ISO8601DateFormatter().string(from: .now)) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(stamped.utf8)); try? h.close()
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
    }
}

/// One run of the job as an iOS 26 continued-processing task: the system keeps
/// it going with the app in the background and shows its progress.
@available(iOS 26, *)
enum ContinuedJob {
    /// Info.plist BGTaskSchedulerPermittedIdentifiers has "<this>.*".
    static let prefix = "com.waleedrizwan.NightOwl.analyze"

    /// Why iOS last refused to run the job in the background, for the progress card.
    @MainActor static var lastRefusal: String?

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
                JobLog.write("started \(id)")
                lastRefusal = nil
                task.progress.totalUnitCount = 1000
                let running = Task { @MainActor in
                    let ok = await work { stage, overall in
                        task.updateTitle(title, subtitle: stage)
                        task.progress.completedUnitCount = Int64(min(max(overall, 0), 1) * 1000)
                    }
                    task.setTaskCompleted(success: ok)
                    done.resume(returning: true)
                }
                task.expirationHandler = { JobLog.write("expired"); running.cancel() }
            }
            guard registered else {
                lastRefusal = "couldn't register \(id)"
                JobLog.write("\(lastRefusal!)")
                done.resume(returning: false)
                return
            }
            let request = BGContinuedProcessingTaskRequest(identifier: id, title: title, subtitle: subtitle)
            request.strategy = .fail          // run now or not at all; we fall back to the foreground
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                lastRefusal = "\(error)"
                JobLog.write("refused: \(error) \((error as NSError).domain) \((error as NSError).code)")
                done.resume(returning: false)
            }
        }
    }
}
