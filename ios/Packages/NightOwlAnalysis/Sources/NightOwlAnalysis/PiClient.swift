import CryptoKit
import Foundation

/// Talks to the Pi's file server (recorder/serve.py) over the home network.
public struct PiClient: Sendable {
    public static let defaultHost = "dreamcatcher.local"
    public static let port = 8642

    public let baseURL: URL
    let token: String
    let session: URLSession

    public init(host: String = defaultHost, token: String) {
        baseURL = URL(string: "http://\(host):\(Self.port)")!
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public enum PiError: Error, CustomStringConvertible {
        case unreachable(String), badToken, server(Int, String), checksum(String)
        public var description: String {
            switch self {
            case .unreachable(let why): "Can't reach the Pi (\(why)). Is it on, and is this phone on your home Wi-Fi?"
            case .badToken: "The Pi didn't accept the token. Paste it again in Settings."
            case .server(let code, let body): "The Pi answered \(code): \(body)"
            case .checksum(let f): "\(f) arrived damaged twice; try again."
            }
        }
    }

    public struct Status: Decodable, Sendable { public let recording: Bool, today: String, stoppedToday: Bool }
    public struct File: Decodable, Sendable { public let name: String, bytes: Int64, complete: Bool }
    public struct Listing: Decodable, Sendable {
        public let night: String, files: [File], bytes: Int64
        public var completeBytes: Int64 { files.filter(\.complete).reduce(0) { $0 + $1.bytes } }
    }

    public func status() async throws -> Status { try await json("status") }
    public func nights() async throws -> [Listing] {
        struct R: Decodable { let nights: [Listing] }
        return try await (json("nights") as R).nights
    }

    /// Ends tonight's recording ("I'm up"); returns once the last file is closed.
    @discardableResult
    public func stop() async throws -> String {
        struct R: Decodable { let stopped: Bool, output: String }
        return try await (json("stop", method: "POST") as R).output
    }

    /// Downloads the night's complete files into dir/<night>/, resuming partial
    /// files and checking each against the Pi's SHA-256. Files already here and
    /// verified are skipped. progress(bytes done, bytes total).
    public func download(_ listing: Listing, into dir: URL, lanes: Int = 2,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let nightDir = dir.appendingPathComponent(listing.night, isDirectory: true)
        try FileManager.default.createDirectory(at: nightDir, withIntermediateDirectories: true)
        let files = listing.files.filter(\.complete)
        let total = files.reduce(0) { $0 + $1.bytes }
        let tally = Tally()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for lane in 0..<max(1, lanes) {
                group.addTask {
                    for f in stride(from: lane, to: files.count, by: max(1, lanes)).map({ files[$0] }) {
                        try await fetch(night: listing.night, file: f, to: nightDir.appendingPathComponent(f.name)) { delta in
                            progress(tally.add(delta), total)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        return nightDir
    }

    // MARK: -

    private func fetch(night: String, file: File, to dest: URL, progress: @Sendable (Int64) -> Void) async throws {
        let verified = dest.appendingPathExtension("ok")
        let fm = FileManager.default
        if fm.fileExists(atPath: verified.path), (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) == file.bytes {
            progress(file.bytes)
            return
        }
        struct Sum: Decodable { let sha256: String }
        let expected = try await (json("nights/\(night)/\(file.name).sha256") as Sum).sha256
        let partial = dest.appendingPathExtension("part")
        for attempt in 1...2 {
            if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
            let have = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
            progress(have)
            if have < file.bytes {
                var req = request("nights/\(night)/\(file.name)")
                req.setValue("bytes=\(have)-", forHTTPHeaderField: "Range")
                let (tmp, response) = try await call { try await session.download(for: req) }
                try check(response, body: nil)
                let handle = try FileHandle(forWritingTo: partial)
                try handle.seekToEnd()
                let got = try Data(contentsOf: tmp, options: .alwaysMapped)
                try handle.write(contentsOf: got)
                try handle.close()
                try? fm.removeItem(at: tmp)
                progress(Int64(got.count))
            }
            if try sha256(partial) == expected {
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: partial, to: dest)
                fm.createFile(atPath: verified.path, contents: nil)
                return
            }
            try? fm.removeItem(at: partial)          // damaged: start this file over once
            progress(-file.bytes)
            if attempt == 2 { throw PiError.checksum(file.name) }
        }
    }

    private func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty { hasher.update(data: block) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if path == "stop" { req.timeoutInterval = 45 }
        return req
    }

    private func json<T: Decodable>(_ path: String, method: String = "GET") async throws -> T {
        let (data, response) = try await call { try await session.data(for: request(path, method: method)) }
        try check(response, body: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let e as URLError {
            throw PiError.unreachable(e.localizedDescription)
        }
    }

    private func check(_ response: URLResponse, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw PiError.badToken }
        guard (200..<300).contains(http.statusCode) else {
            throw PiError.server(http.statusCode, body.map { String(decoding: $0, as: UTF8.self) } ?? "")
        }
    }
}

final class Tally: @unchecked Sendable {
    private var n: Int64 = 0
    private let lock = NSLock()
    func add(_ d: Int64) -> Int64 { lock.lock(); defer { lock.unlock() }; n += d; return n }
}
