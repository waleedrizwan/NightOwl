import Foundation
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

    private(set) var nights: [Night] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var hasFolder = false
    var openNight: String?            // set by a notification tap

    private let bookmarkKey = "folderBookmark"
    private let pendingTokenKey = "pendingDeviceToken"
    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nights.json")
    }

    init() {
        hasFolder = UserDefaults.standard.data(forKey: bookmarkKey) != nil
        if let data = try? Data(contentsOf: cacheURL), let p = try? JSONDecoder().decode(Payload.self, from: data) {
            nights = p.nights
        }
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
            nights = p.nights
            error = nil
            try? data.write(to: cacheURL, options: .atomic)
        } catch {
            self.error = (error as? OwlError)?.message ?? "Couldn't read nights.json: \(error.localizedDescription)"
        }
    }

    /// Copies a clip out of iCloud into the cache so AVAudioPlayer can play it.
    func clipFile(_ path: String) async throws -> URL {
        let local = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let data = try await Task.detached { [self] in
            try withFolder { try Store.read($0.appendingPathComponent(path)) }
        }.value
        try data.write(to: local, options: .atomic)
        return local
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
