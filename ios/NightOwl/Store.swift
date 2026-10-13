import Foundation
import NightOwlAnalysis
import Observation

// MARK: - What the Mac publishes (analysis/publish.py → iCloud Drive/NightOwl/nights.json)

struct Night: Codable, Identifiable, Hashable {
    struct HourBin: Codable, Hashable { let hour: Int; let minutes: Double }
    struct Bin: Codable, Hashable { let startMs: Int; let snoreSec: Int }
    struct Bout: Codable, Hashable { let startMs: Int; let endMs: Int; let sounds: Int; let maxScore: Double; let clip: String? }
    struct Gasp: Codable, Hashable { let tMs: Int; let score: Double; let clip: String? }

    let night: String, dir: String
    let score: Int, band: String
    let startMs: Int, endMs: Int, recordedMs: Int, snoreMs: Int, percentOfNight: Int
    let snoreByHour: [HourBin]
    let timeline: [Bin]
    let bouts: [Bout]
    let gasps: [Gasp]

    var id: String { dir }
    var date: Date { Night.dayFormat.date(from: night) ?? start }
    var start: Date { .init(ms: startMs) }
    var end: Date { .init(ms: endMs) }
    var snoreMinutes: Double { Double(snoreMs) / 60_000 }
    /// Every bout and gasp has a clip (the analysis caps bout clips at 200).
    var hasClips: Bool { bouts.prefix(200).allSatisfy { $0.clip != nil } && gasps.allSatisfy { $0.clip != nil } }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

private struct Payload: Codable { let nights: [Night] }

extension Date {
    init(ms: Int) { self.init(timeIntervalSince1970: Double(ms) / 1000) }
}

// MARK: - Store

/// Reads the nights from a folder in iCloud Drive that the user picks once.
/// The last good copy is cached so the app opens instantly and works offline.
@Observable
final class Store {
    static let shared = Store()

    /// Nights the Mac published (iCloud) and nights analyzed on this iPhone.
    /// The iPhone's copy wins once it has its clips (same numbers, and its clips
    /// play without iCloud); one made before clips existed defers to the Mac's.
    var nights: [Night] {
        var byDir = Dictionary(macNights.map { ($0.dir, $0) }, uniquingKeysWith: { $1 })
        for n in phoneNights where n.hasClips || byDir[n.dir] == nil { byDir[n.dir] = n }
        return byDir.values.sorted { $0.dir < $1.dir }
    }
    private var macNights: [Night] = []
    private(set) var phoneNights: [Night] = []
    private(set) var loading = false
    var error: String?
    private(set) var hasFolder = false
    var openNight: String?            // set by a notification tap or a finished analysis
    var job: Job?                     // analysis on this iPhone in progress (PhoneAnalysis.swift)
    var piStatus: PiClient.Status?    // the Pi's own word on recording and its schedule (nil: unknown)
    var piToken: String? = Keychain.get("token") {
        didSet { Keychain.set("token", piToken) }
    }

    private let bookmarkKey = "folderBookmark"
    private let pendingTokenKey = "pendingDeviceToken"
    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nights.json")
    }
    private var phoneNightsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("phone-nights.json")
    }

    init() {
        hasFolder = UserDefaults.standard.data(forKey: bookmarkKey) != nil
        if let data = try? Data(contentsOf: cacheURL), let p = try? JSONDecoder().decode(Payload.self, from: data) {
            macNights = p.nights
        }
        if let data = try? Data(contentsOf: phoneNightsURL), let p = try? JSONDecoder().decode(Payload.self, from: data) {
            phoneNights = p.nights
        }
    }

    /// The version shown came from this iPhone.
    func isFromPhone(_ n: Night) -> Bool { phoneNights.contains(n) }

    func savePhoneNight(_ n: Night) {
        phoneNights = (phoneNights.filter { $0.dir != n.dir } + [n]).sorted { $0.dir < $1.dir }
        try? FileManager.default.createDirectory(at: phoneNightsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Payload(nights: phoneNights)).write(to: phoneNightsURL, options: .atomic)
    }

    var latest: Night? { nights.last }

    func previous(to n: Night) -> Night? {
        guard let i = nights.firstIndex(of: n), i > 0 else { return nil }
        return nights[i - 1]
    }

    // MARK: folder

    func setFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { error = "Couldn't open that folder."; return }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            hasFolder = true
            error = nil
            if let token = UserDefaults.standard.string(forKey: pendingTokenKey) { registerDevice(token) }
            Task { await refresh() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func withFolder<T>(_ body: (URL) throws -> T) throws -> T {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { throw OwlError.noFolder }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { throw OwlError.noAccess }
        defer { url.stopAccessingSecurityScopedResource() }
        if stale, let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return try body(url)
    }

    /// Coordinated read: makes iCloud download the newest version first.
    private static func read(_ url: URL) throws -> Data {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var coordError: NSError?
        var result: Result<Data, Error> = .failure(OwlError.noData)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            result = Result { try Data(contentsOf: u) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    // MARK: loading

    @MainActor
    func refresh() async {
        guard hasFolder, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let data = try await Task.detached { [self] in
                try withFolder { try Store.read($0.appendingPathComponent("nights.json")) }
            }.value
            let p = try JSONDecoder().decode(Payload.self, from: data)
            macNights = p.nights
            error = nil
            // Application Support doesn't exist on a fresh install until something creates it
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        } catch {
            self.error = (error as? OwlError)?.message ?? "Couldn't read nights.json: \(error.localizedDescription)"
        }
    }

    /// Copies a clip out of iCloud into the cache so AVAudioPlayer can play it.
    /// Clips made on this iPhone are already local.
    func clipFile(_ path: String) async throws -> URL {
        if path.hasPrefix(Store.phoneClipsPrefix) {
            return Store.phoneClipsRoot.deletingLastPathComponent().appendingPathComponent(path)
        }
        let local = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let data = try await Task.detached { [self] in
            try withFolder { try Store.read($0.appendingPathComponent(path)) }
        }.value
        try data.write(to: local, options: .atomic)
        return local
    }

    // MARK: "I'm up"

    /// The Pi records 02:00–12:00; the Mac files each night under the date it was recorded.
    var hasTodaysNight: Bool { latest?.dir == Night.dayFormat.string(from: .now) }

    /// Is the Pi recording? Its own answer when it's reachable, else a guess
    /// from its schedule (by default 02:00-11:00, Toronto time).
    var inRecordingWindow: Bool {
        if let s = piStatus { return s.recording }
        guard Self.cachedSchedule.auto else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Audio.timeZone
        let c = cal.dateComponents([.hour, .minute], from: .now)
        let now = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return (Self.cachedSchedule.start...Self.cachedSchedule.end).contains(now) && now != Self.cachedSchedule.end
    }

    /// When the user last pressed "I'm up"; cleared once today's night shows up.
    var wokeAt: Date? {
        get { access(keyPath: \.wokeAt); return UserDefaults.standard.object(forKey: "wokeAt") as? Date }
        set { withMutation(keyPath: \.wokeAt) { UserDefaults.standard.set(newValue, forKey: "wokeAt") } }
    }

    /// Waiting on the Mac, which only happens without the Pi set up: with it, the
    /// phone does the work itself, and a run that died just offers "I'm up" again.
    var waitingForReport: Bool {
        guard !hasPi, let w = wokeAt, Calendar.current.isDateInToday(w) else { return false }
        return !hasTodaysNight
    }

    /// "I'm up" ran on this phone today but no report came of it (the app was
    /// closed or iOS stopped it mid-way).
    var phoneRunUnfinished: Bool {
        guard hasPi, job == nil, let w = wokeAt, Calendar.current.isDateInToday(w) else { return false }
        return !hasTodaysNight
    }

    /// The Mac's wake.sh watches the iCloud folder for wake.json: it stops the Pi
    /// and runs the morning report.
    @MainActor
    func wake() async {
        do {
            try await Task.detached { [self] in
                try withFolder { folder in
                    let file = folder.appendingPathComponent("wake.json")
                    let body = try JSONEncoder().encode(["at": ISO8601DateFormatter().string(from: .now)])
                    var coordError: NSError?
                    var writeError: Error?
                    NSFileCoordinator().coordinate(writingItemAt: file, options: .forReplacing, error: &coordError) { u in
                        do { try body.write(to: u, options: .atomic) } catch { writeError = error }
                    }
                    if let e = coordError ?? writeError { throw e }
                }
            }.value
            wokeAt = .now
            error = nil
        } catch {
            self.error = (error as? OwlError)?.message ?? "Couldn't reach your Mac: \(error.localizedDescription)"
        }
    }

    // MARK: push

    /// The Mac's notify.py reads devices.json from the same iCloud folder.
    func registerDevice(_ token: String) {
        UserDefaults.standard.set(token, forKey: pendingTokenKey)
        guard hasFolder else { return }
        #if DEBUG
        let env = "development"
        #else
        let env = "production"
        #endif
        Task.detached { [self] in
            try? withFolder { folder in
                let file = folder.appendingPathComponent("devices.json")
                var coordError: NSError?
                NSFileCoordinator().coordinate(writingItemAt: file, options: .forMerging, error: &coordError) { u in
                    var devices = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: u))) ?? [:]
                    guard devices[token] != env else { return }
                    devices[token] = env
                    try? JSONEncoder().encode(devices).write(to: u, options: .atomic)
                }
            }
        }
    }
}

enum OwlError: Error {
    case noFolder, noAccess, noData
    var message: String {
        switch self {
        case .noFolder: "Pick your NightOwl folder in iCloud Drive."
        case .noAccess: "Lost access to the NightOwl folder. Pick it again in Settings."
        case .noData: "No data yet."
        }
    }
}
