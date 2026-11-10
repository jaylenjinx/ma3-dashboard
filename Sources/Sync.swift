import CryptoKit
import Foundation
import Security

// MARK: - Settings

struct SyncSettings: Codable, Equatable {
    var serverURL = ""
    var ma3Shows = true
    var ma3Library = true
    var ma2Shows = true
    var autoSyncMinutes = 0
    var deviceName = Host.current().localizedName ?? "Mac"

    static func load() -> SyncSettings {
        guard let d = UserDefaults.standard.data(forKey: "syncSettings"),
              let s = try? JSONDecoder().decode(SyncSettings.self, from: d) else { return SyncSettings() }
        return s
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "syncSettings") }
}

enum Keychain {
    static let service = "MA3Dashboard Sync"

    static func token() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func setToken(_ token: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard !token.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - What gets synced

/// A local folder mirrored to a remote prefix. Remote paths are platform-neutral
/// ("ma3/2.5.1/shows/x.show"), so other clients (e.g. Windows) can map them to their own folders.
struct SyncRoot: Codable, Hashable {
    let prefix: String
    let dir: String
    var recursive = false
    /// Lowercased filename suffixes to include; empty means everything.
    var suffixes: [String] = []
    /// Regexes matched against the relative path; matches are skipped.
    var exclude: [String] = []

    var dirURL: URL { URL(fileURLWithPath: dir) }

    init(prefix: String, dir: String, recursive: Bool = false, suffixes: [String] = [], exclude: [String] = []) {
        self.prefix = prefix; self.dir = dir; self.recursive = recursive; self.suffixes = suffixes; self.exclude = exclude
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prefix = try c.decode(String.self, forKey: .prefix)
        dir = try c.decode(String.self, forKey: .dir)
        recursive = try c.decodeIfPresent(Bool.self, forKey: .recursive) ?? false
        suffixes = try c.decodeIfPresent([String].self, forKey: .suffixes) ?? []
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
    }

    func includes(_ relative: String) -> Bool {
        let lower = relative.lowercased()
        if !suffixes.isEmpty && !suffixes.contains(where: { lower.hasSuffix($0) }) { return false }
        return !exclude.contains { relative.range(of: $0, options: .regularExpression) != nil }
    }

    static func defaults(_ s: SyncSettings) -> [SyncRoot] {
        let fm = FileManager.default
        var roots: [SyncRoot] = []
        if s.ma3Shows {
            for d in ((try? fm.contentsOfDirectory(atPath: Scanner.maRoot.path)) ?? []).sorted()
            where d.range(of: #"^gma3_\d+\.\d+\.\d+$"#, options: .regularExpression) != nil {
                let shows = Scanner.maRoot.appendingPathComponent("\(d)/shared/shows")
                if fm.fileExists(atPath: shows.path) {
                    roots.append(SyncRoot(prefix: "ma3/\(d.dropFirst(5))/shows", dir: shows.path, suffixes: [".show"]))
                }
            }
        }
        if s.ma3Library {
            let lib = Scanner.maRoot.appendingPathComponent("gma3_library")
            roots.append(SyncRoot(prefix: "ma3/library/colorthemes", dir: lib.appendingPathComponent("colorthemes").path,
                                  suffixes: [".xml"]))
            roots.append(SyncRoot(prefix: "ma3/library/fixturetypes", dir: lib.appendingPathComponent("fixturetypes").path,
                                  suffixes: [".gdtf", ".xml", ".pxml"]))
            roots.append(SyncRoot(prefix: "ma3/library/datapools", dir: lib.appendingPathComponent("datapools").path,
                                  recursive: true, exclude: [#"\.bak(-|$)"#, #"(^|/)libcache\.dat$"#]))
        }
        if s.ma2Shows {
            // One local folder per remote path: if a version is in both CrossOver and Parallels, CrossOver's is used.
            var seen = Set<String>()
            for (v, dir, _) in Scanner.ma2DataDirs() where seen.insert(v).inserted {
                roots.append(SyncRoot(prefix: "ma2/\(v)/shows", dir: dir.appendingPathComponent("shows").path,
                                      suffixes: [".show.gz", ".show"]))
            }
        }
        return roots
    }
}

// MARK: - Server API

struct RemoteEntry: Codable {
    let sha: String?
    let size: Int64
    let mtime: Double
    let rev: Int
    var deleted: Bool?
    var device: String?
}

struct Manifest: Codable {
    let rev: Int
    let files: [String: RemoteEntry]
}

struct SyncError: LocalizedError {
    let message: String
    var status = 0
    var errorDescription: String? { message }
}

struct SyncClient {
    let base: URL
    let token: String
    let device: String
    static let chunkSize = 16 * 1024 * 1024
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: c)
    }()

    init(server: String, token: String, device: String) throws {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            throw SyncError(message: "Server URL must start with https:// (or http:// on your LAN)")
        }
        guard !token.isEmpty else { throw SyncError(message: "Enter the server's SYNC_TOKEN") }
        base = url; self.token = token; self.device = device
    }

    private func request(_ path: String, _ query: [String: String] = [:], method: String = "GET") -> URLRequest {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var r = URLRequest(url: c.url!)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func check(_ data: Data, _ resp: URLResponse) throws -> Data {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw SyncError(message: code == 401 ? "Wrong sync token" : "Server error \(code): \(msg)", status: code)
        }
        return data
    }

    private func send(_ r: URLRequest, body: Data? = nil) async throws -> Data {
        if let body {
            let (data, resp) = try await session.upload(for: r, from: body)
            return try check(data, resp)
        }
        let (data, resp) = try await session.data(for: r)
        return try check(data, resp)
    }

    func health() async throws {
        let (data, resp) = try await session.data(for: request("api/health"))
        _ = try check(data, resp)
        _ = try await manifest() // also proves the token works
    }

    func manifest() async throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: try await send(request("api/manifest")))
    }

    /// Uploads in chunks; `baseSha` is what we believe the server has (nil = nothing), so a concurrent change returns 409.
    func upload(_ file: URL, as path: String, sha: String, mtime: Double, baseSha: String?) async throws {
        let start = try await send(request("api/uploads", method: "POST"))
        guard let id = (try JSONSerialization.jsonObject(with: start) as? [String: Any])?["id"] as? String else {
            throw SyncError(message: "Bad upload response")
        }
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var offset = 0
        while let chunk = try h.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            var r = request("api/uploads/\(id)", ["offset": String(offset)], method: "PUT")
            r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            _ = try await send(r, body: chunk)
            offset += chunk.count
        }
        var commit = request("api/uploads/\(id)/commit", method: "POST")
        commit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["path": path, "sha": sha, "mtime": mtime, "device": device]
        body["baseSha"] = baseSha ?? NSNull()
        _ = try await send(commit, body: try JSONSerialization.data(withJSONObject: body))
    }

    func download(_ path: String) async throws -> URL {
        let (tmp, resp) = try await session.download(for: request("api/file", ["path": path]))
        if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
            throw SyncError(message: "Download failed (\(code)) for \(path)", status: code)
        }
        // URLSession deletes its temp file when this call returns, so keep our own copy.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("MA3Dashboard-dl-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: tmp, to: keep)
        return keep
    }

    func delete(_ path: String, baseSha: String?) async throws {
        var q = ["path": path, "device": device]
        if let baseSha { q["baseSha"] = baseSha }
        _ = try await send(request("api/file", q, method: "DELETE"))
    }
}

// MARK: - Engine

struct SyncLogEntry: Identifiable, Hashable {
    enum Kind: String { case upload = "↑", download = "↓", delete = "✕", conflict = "⚠︎", error = "!", info = "·" }
    let id = UUID()
    let date = Date()
    let kind: Kind
    let path: String
    let detail: String
}

struct SyncSummary {
    var uploaded = 0, downloaded = 0, deleted = 0, conflicts = 0, errors = 0, pending = 0
    var text: String {
        let parts = [(uploaded, "up"), (downloaded, "down"), (deleted, "deleted"), (conflicts, "conflicts"), (errors, "errors")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "Everything up to date" : parts.joined(separator: " · ")
    }
}

/// Three-way sync per file between the local folder, the server, and the state at the last sync.
/// Changes on one side propagate; changes on both sides keep both copies; deletions go to the Trash
/// locally and to versions/ on the server.
final class SyncEngine {
    struct StateEntry: Codable { var sha: String; var size: Int64; var mtime: Double }
    struct State: Codable { var files: [String: StateEntry] = [:] }

    let client: SyncClient
    let roots: [SyncRoot]
    let statePath: URL
    let log: (SyncLogEntry) -> Void
    /// Files modified more recently than this are probably still being written by onPC.
    var settleSeconds: TimeInterval = 15
    private var state = State()

    /// One state file per server, so switching servers never mistakes "not on this server" for "deleted".
    static func statePath(for server: URL) -> URL {
        let key = SHA256.hash(data: Data(server.absoluteString.lowercased().utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MA3Dashboard/sync-state-\(key).json")
    }

    init(client: SyncClient, roots: [SyncRoot], statePath: URL? = nil, log: @escaping (SyncLogEntry) -> Void) {
        self.client = client; self.roots = roots; self.log = log
        self.statePath = statePath ?? Self.statePath(for: client.base)
    }

    struct LocalFile { let url: URL; let size: Int64; let mtime: Double }

    func run() async throws -> SyncSummary {
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: statePath))) ?? State()
        let manifest = try await client.manifest()
        var summary = SyncSummary()

        for root in roots {
            let local = scan(root)
            let prefix = root.prefix + "/"
            let remote = manifest.files.filter { $0.key.hasPrefix(prefix) && root.includes(String($0.key.dropFirst(prefix.count))) }
            let known = state.files.keys.filter { $0.hasPrefix(prefix) }
            for path in Set(local.keys).union(remote.keys).union(known).sorted() {
                do {
                    try await syncOne(path, root: root, local: local[path], remote: remote[path], summary: &summary)
                } catch {
                    summary.errors += 1
                    log(.init(kind: .error, path: path, detail: error.localizedDescription))
                }
            }
        }
        try saveState()
        return summary
    }

    private func scan(_ root: SyncRoot) -> [String: LocalFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var out: [String: LocalFile] = [:]
        let urls: [URL]
        if root.recursive {
            urls = (fm.enumerator(at: root.dirURL, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)?
                .compactMap { $0 as? URL }) ?? []
        } else {
            urls = (try? fm.contentsOfDirectory(at: root.dirURL, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        }
        let base = root.dirURL.standardizedFileURL.path + "/"
        for u in urls {
            guard let rv = try? u.resourceValues(forKeys: Set(keys)), rv.isRegularFile == true else { continue }
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count))
            guard root.includes(rel) else { continue }
            out[root.prefix + "/" + rel] = LocalFile(url: u, size: Int64(rv.fileSize ?? 0),
                                                     mtime: (rv.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        }
        return out
    }

    private func localURL(_ path: String, _ root: SyncRoot) -> URL {
        root.dirURL.appendingPathComponent(String(path.dropFirst(root.prefix.count + 1)))
    }

    private func syncOne(_ path: String, root: SyncRoot, local: LocalFile?, remote r: RemoteEntry?,
                         summary: inout SyncSummary) async throws {
        if let local, Date().timeIntervalSince1970 - local.mtime < settleSeconds { summary.pending += 1; return }
        // Only an explicit deletion record on the server counts as "deleted remotely". A path the server has
        // never heard of (new or reset server) is treated as never synced, so local files get uploaded, not trashed.
        let base = r == nil ? nil : state.files[path]
        let lsha = try local.map { l -> String in
            if let base, base.size == l.size, base.mtime == l.mtime { return base.sha }
            return try Self.sha256(l.url)
        }
        let rsha = r?.deleted == true ? nil : r?.sha

        if lsha == rsha {
            if let lsha, let local { state.files[path] = .init(sha: lsha, size: local.size, mtime: local.mtime) }
            else { state.files[path] = nil }
            return
        }
        let localChanged = lsha != base?.sha
        let remoteChanged = rsha != base?.sha

        switch (localChanged, remoteChanged) {
        case (true, false), (true, true) where rsha == nil:
            if let local, let lsha {
                try await upload(local, lsha, as: path, baseSha: rsha)
                summary.uploaded += 1
            } else {
                try await client.delete(path, baseSha: rsha)
                state.files[path] = nil
                summary.deleted += 1
                log(.init(kind: .delete, path: path, detail: "Deleted on server (kept in its history)"))
            }
        case (false, true), (true, true) where lsha == nil:
            if let r, rsha != nil {
                try await download(path, r, to: localURL(path, root))
                summary.downloaded += 1
            } else if let local {
                try FileManager.default.trashItem(at: local.url, resultingItemURL: nil)
                state.files[path] = nil
                summary.deleted += 1
                log(.init(kind: .delete, path: path, detail: "Deleted on another machine; moved to Trash"))
            }
        case (true, true):
            // Both sides changed: keep the local edit under a conflict name, take the server's copy as the original.
            guard let local, let lsha, let r else { return }
            let conflictURL = Self.conflictName(for: local.url, device: client.device)
            try FileManager.default.moveItem(at: local.url, to: conflictURL)
            let conflictPath = root.prefix + "/" + String(conflictURL.standardizedFileURL.path
                .dropFirst(root.dirURL.standardizedFileURL.path.count + 1))
            let moved = LocalFile(url: conflictURL, size: local.size, mtime: local.mtime)
            try await upload(moved, lsha, as: conflictPath, baseSha: nil)
            try await download(path, r, to: local.url)
            summary.conflicts += 1
            log(.init(kind: .conflict, path: path, detail: "Changed on both sides; your copy kept as \(conflictURL.lastPathComponent)"))
        case (false, false):
            break
        }
        try saveState()
    }

    private func upload(_ local: LocalFile, _ sha: String, as path: String, baseSha: String?) async throws {
        do {
            try await client.upload(local.url, as: path, sha: sha, mtime: local.mtime * 1000, baseSha: baseSha)
        } catch let e as SyncError where e.status == 409 {
            throw SyncError(message: "Changed on the server during sync; will retry next sync")
        }
        state.files[path] = .init(sha: sha, size: local.size, mtime: local.mtime)
        log(.init(kind: .upload, path: path, detail: ByteCountFormatter.string(fromByteCount: local.size, countStyle: .file)))
    }

    private func download(_ path: String, _ r: RemoteEntry, to dest: URL) async throws {
        let fm = FileManager.default
        let tmp = try await client.download(path)
        defer { try? fm.removeItem(at: tmp) }
        let sha = try Self.sha256(tmp)
        guard sha == r.sha else { throw SyncError(message: "Checksum mismatch downloading \(path)") }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: r.mtime / 1000)], ofItemAtPath: tmp.path)
        if fm.fileExists(atPath: dest.path) { _ = try fm.replaceItemAt(dest, withItemAt: tmp) }
        else { try fm.moveItem(at: tmp, to: dest) }
        let rv = try dest.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        state.files[path] = .init(sha: sha, size: Int64(rv.fileSize ?? 0),
                                  mtime: (rv.contentModificationDate ?? Date()).timeIntervalSince1970)
        log(.init(kind: .download, path: path, detail: ByteCountFormatter.string(fromByteCount: r.size, countStyle: .file)
                  + (r.device.map { $0.isEmpty ? "" : " from \($0)" } ?? "")))
    }

    private func saveState() throws {
        try FileManager.default.createDirectory(at: statePath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: statePath, options: .atomic)
    }

    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 4 * 1024 * 1024), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func conflictName(for url: URL, device: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let name = url.lastPathComponent
        // Keep double extensions like ".show.gz" intact.
        let ext = name.lowercased().hasSuffix(".show.gz") ? ".show.gz" : (url.pathExtension.isEmpty ? "" : "." + url.pathExtension)
        let stem = String(name.dropLast(ext.count))
        let safeDevice = device.replacingOccurrences(of: "/", with: "-")
        return LibraryFiles.uniqueDestination(url.deletingLastPathComponent()
            .appendingPathComponent("\(stem) (conflict \(safeDevice) \(f.string(from: Date())))\(ext)"))
    }
}

// MARK: - Headless mode for testing: MA3Dashboard --sync-once config.json

enum HeadlessSync {
    struct Config: Codable {
        let server: String
        let token: String
        let device: String
        let statePath: String
        let roots: [SyncRoot]
        var settleSeconds: Double?
    }

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--sync-once"), i + 1 < args.count else { return }
        let done = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            do {
                let cfg = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: args[i + 1])))
                let engine = SyncEngine(client: try SyncClient(server: cfg.server, token: cfg.token, device: cfg.device),
                                        roots: cfg.roots, statePath: URL(fileURLWithPath: cfg.statePath)) {
                    print("\($0.kind.rawValue) \($0.path)  \($0.detail)")
                }
                engine.settleSeconds = cfg.settleSeconds ?? 15
                print("== \(try await engine.run().text)")
            } catch {
                print("FAILED: \(error.localizedDescription)"); code = 1
            }
            done.signal()
        }
        done.wait()
        exit(code)
    }
}
