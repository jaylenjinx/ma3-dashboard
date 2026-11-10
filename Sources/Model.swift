import AppKit
import Foundation
import Network

struct ShowFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date
    /// Set for a show listed from inside a Parallels VM whose drive isn't mounted in macOS.
    var remote: ParallelsRef? = nil
    var id: URL { url }
    /// grandMA3 shows are "x.show"; grandMA2 shows are "x.show.gz".
    var name: String {
        let n = url.lastPathComponent
        for ext in [".show.gz", ".show"] where n.lowercased().hasSuffix(ext) { return String(n.dropLast(ext.count)) }
        return url.deletingPathExtension().lastPathComponent
    }
    var fileExtension: String { String(url.lastPathComponent.dropFirst(name.count)) }
}

enum Product: String, Hashable {
    case ma3, ma2
    var title: String { self == .ma3 ? "grandMA3 onPC" : "grandMA2 onPC" }
}

/// Where a Windows-only grandMA2 install runs on this Mac.
enum WinHost: String, Hashable, CaseIterable {
    case crossover, parallels
    var title: String { self == .crossover ? "CrossOver" : "Parallels" }
}

/// One launchable onPC build. 2.5+ ships as standalone "grandMA3 onPC x.y.z.w.app" bundles;
/// older versions live as gma3_<x.y.z> slots inside the grandMA3.app launcher, which starts
/// whichever slot its Contents/MacOS/current_version file names.
struct MABuild: Identifiable, Hashable {
    enum Kind: Hashable {
        case app(URL)
        case launcherSlot(launcher: URL, slot: String)
        /// A CrossOver wrapper app that starts grandMA2 onPC inside a Wine bottle.
        case crossover(URL)
        /// grandMA2 onPC in a Parallels VM: the wrapper app Parallels made for it, plus the VM and exe so
        /// CleanStart (which has no wrapper) can be started with `prlctl exec`.
        case parallels(app: URL, vm: String, exe: String)
    }
    let fullVersion: String
    let kind: Kind
    var product: Product = .ma3
    var cleanStart = false
    var id: String { "\(product.rawValue) \(fullVersion)\(cleanStart ? " clean" : "")\(host == .parallels ? " parallels" : "")" }
    var dataVersion: String { fullVersion.split(separator: ".").prefix(3).joined(separator: ".") }
    var name: String {
        switch kind {
        case .app(let url), .crossover(let url): return url.deletingPathExtension().lastPathComponent
        case .parallels(_, _, let exe):
            let folder = exe.split(separator: "\\").dropLast().last.map(String.init) ?? "grandMA2 onPC \(fullVersion)"
            return folder + (cleanStart ? " CleanStart" : "")
        case .launcherSlot(let l, _): return "\(l.deletingPathExtension().lastPathComponent) (\(fullVersion))"
        }
    }

    func owns(_ command: String) -> Bool {
        switch kind {
        case .app(let url): return command.hasPrefix(url.path + "/")
        case .launcherSlot(let l, let slot): return command.hasPrefix(l.path + "/Contents/MacOS/gma3_\(slot)/")
        case .crossover:
            return !cleanStart && !command.hasPrefix(Scanner.parallelsTag) && command.lowercased().contains("gma2onpc.exe")
        case .parallels:
            // Windows has no "CleanStart" process name, so a running gma2onpc.exe is credited to the normal build.
            return !cleanStart && command.hasPrefix(Scanner.parallelsTag) && command.contains("grandMA2 onPC \(fullVersion)\\")
        }
    }

    var url: URL {
        switch kind {
        case .app(let u), .crossover(let u), .parallels(let u, _, _): return u
        case .launcherSlot(let l, _): return l
        }
    }
    var host: WinHost? {
        switch kind {
        case .crossover: return .crossover
        case .parallels: return .parallels
        default: return nil
        }
    }
}

/// A gma3_<x.y.z> data folder (shows, backups) plus the builds that use it.
struct MAVersion: Identifiable, Hashable {
    var product: Product = .ma3
    /// For grandMA2: CrossOver or Parallels. A version installed in both shows up once per host.
    var host: WinHost? = nil
    let version: String
    let builds: [MABuild]
    let showsDir: URL
    let shows: [ShowFile]
    let backupCount: Int
    let running: (build: MABuild, pid: Int32)?
    var id: String {
        switch (product, host) {
        case (.ma3, _): return version
        case (.ma2, .parallels?): return "ma2:parallels:\(version)"
        default: return "ma2:\(version)"
        }
    }
    /// Shown when there are no shows because the VM's disk isn't visible from macOS.
    var unavailableNote: String? = nil
    /// The gma2_V_ folder inside a Parallels VM, when shows are read through prlctl rather than a mounted drive.
    var winDir: ParallelsRef? = nil
    var pid: Int32? { running?.pid }
    var isRunning: Bool { running != nil }
    var newestBuild: MABuild? { builds.first }

    static func == (a: MAVersion, b: MAVersion) -> Bool {
        a.id == b.id && a.builds == b.builds && a.shows == b.shows && a.pid == b.pid && a.backupCount == b.backupCount && a.unavailableNote == b.unavailableNote
    }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum Scanner {
    static let maRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("MALightingTechnology")
    static let launcherURL = URL(fileURLWithPath: "/Applications/grandMA3.app")
    static let oscPort: UInt16 = 8000

    static func scan() -> (versions: [MAVersion], oscListening: Bool) {
        let builds = findBuilds()
        let procs = runningProcesses()
        let fm = FileManager.default

        let dirs = ((try? fm.contentsOfDirectory(atPath: maRoot.path)) ?? [])
            .filter { $0.range(of: #"^gma3_\d+\.\d+\.\d+$"#, options: .regularExpression) != nil }
            .map { String($0.dropFirst(5)) }
        let all = Set(dirs).union(builds.map(\.dataVersion))

        let versions = all.map { v -> MAVersion in
            let base = maRoot.appendingPathComponent("gma3_\(v)/shared")
            let showsDir = base.appendingPathComponent("shows")
            let mine = builds.filter { $0.dataVersion == v }
            var running: (MABuild, Int32)?
            for p in procs { if let b = mine.first(where: { $0.owns(p.command) }) { running = (b, p.pid); break } }
            return MAVersion(
                version: v, builds: mine, showsDir: showsDir,
                shows: listShows(showsDir),
                backupCount: listShows(base.appendingPathComponent("backups")).count,
                running: running)
        }
        .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        return (versions + scanMA2(procs: procs), oscListening())
    }

    // MARK: grandMA2 (CrossOver)

    static let crossoverBottles = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CrossOver/Bottles")
    static let crossoverApps = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/CrossOver")

    static let ma2DataPath = "ProgramData/MA Lighting Technologies/grandma"

    /// gma2_V_<x.y.z> data folders, from every CrossOver bottle and every Parallels VM disk mounted in macOS.
    static func ma2DataDirs(_ host: WinHost? = nil) -> [(version: String, dir: URL, host: WinHost)] {
        let fm = FileManager.default
        var roots: [(URL, WinHost)] = []
        if host != .parallels {
            let bottles = (try? fm.contentsOfDirectory(at: crossoverBottles, includingPropertiesForKeys: nil)) ?? []
            roots += bottles.map { ($0.appendingPathComponent("drive_c/" + ma2DataPath), .crossover) }
        }
        if host != .crossover {
            roots += parallelsVolumes().map { ($0.url.appendingPathComponent(ma2DataPath), .parallels) }
        }
        return roots.flatMap { root, h -> [(String, URL, WinHost)] in
            ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0.hasPrefix("gma2_V_") }
                .map { (String($0.dropFirst(7)), root.appendingPathComponent($0), h) }
        }
    }

    /// CrossOver wrapper apps named "grandMA2 onPC <version>[ CleanStart].app", from the Start Menu shortcuts
    /// (the uninstall and "Open Show Folder" ones don't match), plus a normal and a CleanStart build for every
    /// gma2onpc.exe that Parallels has a wrapper for.
    static func findMA2Builds() -> [MABuild] {
        var builds: [MABuild] = []
        let e = FileManager.default.enumerator(at: crossoverApps, includingPropertiesForKeys: nil,
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = e?.nextObject() as? URL {
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "app", name.hasPrefix("grandMA2 onPC "),
                  let r = name.range(of: #"\d+(\.\d+){2,3}"#, options: .regularExpression) else { continue }
            builds.append(MABuild(fullVersion: String(name[r]), kind: .crossover(url), product: .ma2,
                                  cleanStart: name.hasSuffix("CleanStart")))
        }
        for w in Parallels.wrappers() where w.exe.lowercased().hasSuffix("\\gma2onpc.exe") {
            guard let r = w.folder.range(of: #"\d+(\.\d+){2,3}"#, options: .regularExpression) else { continue }
            for clean in [false, true] {
                builds.append(MABuild(fullVersion: String(w.folder[r]), kind: .parallels(app: w.url, vm: w.vm, exe: w.exe),
                                      product: .ma2, cleanStart: clean))
            }
        }
        return builds.sorted { ($0.fullVersion, $0.cleanStart ? 0 : 1) > ($1.fullVersion, $1.cleanStart ? 0 : 1) }
    }

    static func scanMA2(procs: [(pid: Int32, command: String)]) -> [MAVersion] {
        let builds = findMA2Builds()
        let dirs = ma2DataDirs()
        let hasParallels = builds.contains { $0.host == .parallels }
        let vms = hasParallels ? Parallels.query() : [:]
        let procs = procs + vms.values.flatMap { $0.procs.map { ($0.pid, parallelsTag + $0.path) } }
        let vmNames = Dictionary(Parallels.wrappers().map { ($0.vm, $0.vmName) }, uniquingKeysWith: { a, _ in a })

        var keys = Set<String>()
        for d in dirs { keys.insert("\(d.host.rawValue) \(d.version)") }
        for b in builds { if let h = b.host { keys.insert("\(h.rawValue) \(b.dataVersion)") } }
        for st in vms.values { for v in st.versions { keys.insert("parallels \(v)") } }

        return keys.compactMap { key -> MAVersion? in
            let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
            guard let host = WinHost(rawValue: parts[0]) else { return nil }
            let v = parts[1]
            let mine = builds.filter { $0.host == host && $0.dataVersion == v }
            var running: (MABuild, Int32)?
            for p in procs { if let b = mine.first(where: { $0.owns(p.command) }) { running = (b, p.pid); break } }

            if let dir = dirs.first(where: { $0.host == host && $0.version == v })?.dir {
                let showsDir = dir.appendingPathComponent("shows")
                let files = (try? FileManager.default.contentsOfDirectory(atPath: showsDir.path)) ?? []
                return MAVersion(product: .ma2, host: host, version: v, builds: mine, showsDir: showsDir,
                                 shows: listShows(showsDir),
                                 backupCount: files.filter { $0.hasSuffix(".backup") }.count, running: running)
            }
            guard host == .parallels else {
                return MAVersion(product: .ma2, host: host, version: v, builds: mine, showsDir: crossoverBottles,
                                 shows: [], backupCount: 0, running: running)
            }
            // Not mounted in macOS: read the VM's folder through prlctl.
            let vmID: String? = {
                if case .parallels(_, let vm, _)? = mine.first?.kind { return vm }
                return vms.first { $0.value.versions.contains(v) }?.key
            }()
            let state = vmID.flatMap { vms[$0] }
            let winDir = vmID.map { ParallelsRef(vm: $0, path: Parallels.ma2Data + "\\gma2_V_\(v)") }
            var shows: [ShowFile] = []
            var backups = 0
            if let state, let vmID, let winDir {
                for s in state.shows where s.version == v {
                    if s.name.lowercased().hasSuffix(".backup") { backups += 1 }
                    guard s.name.lowercased().hasSuffix(".show.gz") || s.name.lowercased().hasSuffix(".show") else { continue }
                    shows.append(ShowFile(url: URL(fileURLWithPath: "/parallels/\(vmID)/\(v)/\(s.name)"), size: s.size,
                                          modified: Date(timeIntervalSince1970: s.mtime),
                                          remote: ParallelsRef(vm: vmID, path: winDir.path + "\\shows\\" + s.name)))
                }
                shows.sort { $0.modified > $1.modified }
            }
            let vmName = vmID.flatMap { vmNames[$0] } ?? "the Parallels VM"
            let note: String? = state != nil ? nil
                : prlctlMissing ? "Can't reach \(vmName): prlctl isn't installed."
                : "Start \(vmName) to see its showfiles."
            return MAVersion(product: .ma2, host: host, version: v, builds: mine,
                             showsDir: Parallels.appsDir, shows: shows, backupCount: backups, running: running,
                             unavailableNote: note, winDir: state == nil ? nil : winDir)
        }
        .sorted { a, b in
            a.host != b.host ? a.host == .crossover : a.version.compare(b.version, options: .numeric) == .orderedDescending
        }
    }

    // MARK: grandMA2 (Parallels Desktop): see Parallels.swift

    static var prlctlMissing: Bool { Parallels.prlctl == nil }
    /// Marks process entries that came from inside a Parallels VM, so CrossOver builds never claim them.
    static let parallelsTag = "parallels:"

    /// Windows drives Parallels mounts for "Access Windows folders from Mac": "/Volumes/[C] <VM name>.hidden".
    /// Only names of that shape are touched, so a slow network share in /Volumes is never stat'ed.
    static func parallelsVolumes() -> [(url: URL, vmName: String)] {
        let vols = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return vols.compactMap { name in
            guard let m = name.range(of: #"^\[[A-Z]\] "#, options: .regularExpression) else { return nil }
            var vm = String(name[m.upperBound...])
            if vm.hasSuffix(".hidden") { vm = String(vm.dropLast(7)) }
            return (URL(fileURLWithPath: "/Volumes").appendingPathComponent(name), vm)
        }
    }

    static func findBuilds() -> [MABuild] {
        var builds: [MABuild] = []
        let fm = FileManager.default
        let apps = URL(fileURLWithPath: "/Applications")
        for name in (try? fm.contentsOfDirectory(atPath: apps.path)) ?? []
        where name.hasPrefix("grandMA3 onPC") && name.hasSuffix(".app") {
            let url = apps.appendingPathComponent(name)
            if let v = bundleVersion(url.appendingPathComponent("Contents/Info.plist")) {
                builds.append(MABuild(fullVersion: v, kind: .app(url)))
            }
        }
        let macos = launcherURL.appendingPathComponent("Contents/MacOS")
        for slot in (try? fm.contentsOfDirectory(atPath: macos.path)) ?? [] where slot.hasPrefix("gma3_") {
            let dir = macos.appendingPathComponent(slot)
            // Slots without app_gma3 (e.g. "2.5.1_application") just hand off to a standalone app.
            guard fm.fileExists(atPath: dir.appendingPathComponent("app_gma3").path),
                  let v = bundleVersion(dir.appendingPathComponent("Info.plist")) else { continue }
            builds.append(MABuild(fullVersion: v, kind: .launcherSlot(launcher: launcherURL, slot: String(slot.dropFirst(5)))))
        }
        return builds.sorted { $0.fullVersion.compare($1.fullVersion, options: .numeric) == .orderedDescending }
    }

    static func bundleVersion(_ plist: URL) -> String? {
        guard let d = NSDictionary(contentsOf: plist) else { return nil }
        return (d["CFBundleVersion"] as? String) ?? (d["CFBundleShortVersionString"] as? String)
    }

    static func listShows(_ dir: URL) -> [ShowFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        return urls.filter { $0.lastPathComponent.lowercased().hasSuffix(".show")
            || $0.lastPathComponent.lowercased().hasSuffix(".show.gz") }.map { url in
            let rv = try? url.resourceValues(forKeys: Set(keys))
            return ShowFile(url: url, size: Int64(rv?.fileSize ?? 0), modified: rv?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.modified > $1.modified }
    }

    static func runningProcesses() -> [(pid: Int32, command: String)] {
        shell("/bin/ps", ["-axo", "pid=,command="])
            .split(separator: "\n")
            .compactMap { line -> (Int32, String)? in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.range(of: #"/app_gma3(\s|$)|gma2onpc\.exe"#, options: [.regularExpression, .caseInsensitive]) != nil,
                      let sp = t.firstIndex(of: " "), let pid = Int32(t[..<sp]) else { return nil }
                return (pid, String(t[sp...]).trimmingCharacters(in: .whitespaces))
            }
    }

    static func oscListening() -> Bool {
        shell("/usr/sbin/lsof", ["-nP", "-iUDP:\(oscPort)"]).contains("app_gma3")
    }

    @discardableResult
    static func shell(_ path: String, _ args: [String], status: UnsafeMutablePointer<Int32>? = nil,
                      timeout: TimeInterval? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { status?.pointee = -1; return "" }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        status?.pointee = p.terminationStatus
        return String(decoding: data, as: UTF8.self)
    }
}

enum OSC {
    /// Sends a single-string OSC message to onPC on localhost.
    static func send(_ address: String, _ string: String) async throws {
        func pad(_ s: String) -> Data {
            var d = Data(s.utf8); d.append(0)
            while d.count % 4 != 0 { d.append(0) }
            return d
        }
        let packet = pad(address) + pad(",s") + pad(string)
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Scanner.oscPort)!, using: .udp)
        conn.start(queue: .global())
        defer { conn.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: packet, completion: .contentProcessed { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            })
        }
    }
}

@MainActor
@Observable
final class Store {
    var versions: [MAVersion] = []
    var oscListening = false
    var selection: SidebarItem? = SidebarItem(rawValue: UserDefaults.standard.string(forKey: "sidebar") ?? "") {
        didSet { UserDefaults.standard.set(selection?.rawValue, forKey: "sidebar") }
    }
    var message: (text: String, isError: Bool)?

    var libraries: [LibraryLocation] = []
    var libraryURL: URL? = UserDefaults.standard.url(forKey: "library") {
        didSet { UserDefaults.standard.set(libraryURL, forKey: "library"); refreshLibrary() }
    }
    var themes: [ColorTheme] = []
    var fixtures: [FixtureType] = []
    var pools: [Datapool] = []
    var loadingLibrary = false

    var installers: [InstallerPackage] = []
    var installing: [URL: String] = [:]
    private var timer: Timer?

    var syncSettings = SyncSettings.load() {
        didSet { if syncSettings != oldValue { syncSettings.save(); scheduleAutoSync() } }
    }
    var syncing = false
    var syncLog: [SyncLogEntry] = []
    var lastSync: Date? = UserDefaults.standard.object(forKey: "lastSync") as? Date
    var lastSyncSummary: String?
    var syncError: String?
    private var autoSyncTimer: Timer?

    var selected: MAVersion? {
        if case .version(let v) = selection { return versions.first { $0.id == v } }
        return nil
    }
    var library: LibraryLocation? { libraries.first { $0.url == libraryURL } ?? libraries.first }
    var allBuilds: [MABuild] { versions.flatMap(\.builds) }

    func start() {
        refresh()
        refreshLibrary()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        scheduleAutoSync()
        if syncSettings.autoSyncMinutes > 0 { syncNow() }
    }

    // MARK: Cloud sync

    func scheduleAutoSync() {
        autoSyncTimer?.invalidate()
        let m = syncSettings.autoSyncMinutes
        guard m > 0 else { return }
        autoSyncTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(m * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
    }

    func syncNow() {
        guard !syncing else { return }
        let settings = syncSettings
        let client: SyncClient
        do { client = try SyncClient(server: settings.serverURL, token: Keychain.token() ?? "", device: settings.deviceName) }
        catch { syncError = error.localizedDescription; return }
        syncing = true
        syncError = nil
        Task.detached {
            let engine = SyncEngine(client: client, roots: SyncRoot.defaults(settings)) { entry in
                Task { @MainActor in
                    self.syncLog.insert(entry, at: 0)
                    if self.syncLog.count > 300 { self.syncLog.removeLast(self.syncLog.count - 300) }
                }
            }
            let result: Result<SyncSummary, Error>
            do { result = .success(try await engine.run()) } catch { result = .failure(error) }
            await MainActor.run {
                self.syncing = false
                switch result {
                case .success(let s):
                    self.lastSync = Date()
                    UserDefaults.standard.set(self.lastSync, forKey: "lastSync")
                    self.lastSyncSummary = s.text + (s.pending > 0 ? " · \(s.pending) waiting for onPC to finish writing" : "")
                    if s.downloaded + s.deleted + s.conflicts > 0 { self.refresh(); self.refreshLibrary() }
                case .failure(let e):
                    self.syncError = e.localizedDescription
                }
            }
        }
    }

    func testConnection(server: String, token: String) async -> String? {
        do {
            try await SyncClient(server: server, token: token, device: syncSettings.deviceName).health()
            return nil
        } catch { return error.localizedDescription }
    }

    private var scanning = false
    private var scanningInstallers = false
    private var lastInstallerScan = Date.distantPast

    func refresh() {
        // Installers live in ~/Downloads, which can block on a macOS privacy prompt, so they're scanned
        // separately and less often; versions never wait on them. Neither scan overlaps itself.
        if !scanningInstallers && (selection == .install || Date().timeIntervalSince(lastInstallerScan) > 60) {
            scanningInstallers = true
            Task.detached {
                let pkgs = InstallerScanner.scan()
                await MainActor.run {
                    if self.installers != pkgs { self.installers = pkgs }
                    self.scanningInstallers = false
                    self.lastInstallerScan = Date()
                }
            }
        }
        guard !scanning else { return }
        scanning = true
        Task.detached {
            let result = Scanner.scan()
            await MainActor.run {
                self.scanning = false
                if self.versions != result.versions { self.versions = result.versions }
                self.oscListening = result.oscListening
                if self.selection == nil {
                    let v = result.versions.first { $0.isRunning } ?? result.versions.first
                    self.selection = v.map { .version($0.id) }
                }
            }
        }
    }

    func refreshLibrary() {
        libraries = LibraryLocation.all()
        guard let lib = library else { themes = []; fixtures = []; pools = []; return }
        loadingLibrary = true
        Task.detached {
            let t = ThemeScanner.scan(lib.themesDir)
            let f = FixtureScanner.scan(lib.fixturesDir)
            let p = DatapoolScanner.scan(lib.datapoolsDir)
            await MainActor.run {
                self.themes = t
                self.fixtures = f
                self.pools = p
                self.loadingLibrary = false
            }
        }
    }

    func flash(_ text: String, error: Bool = false) {
        message = (text, error)
        Task {
            try? await Task.sleep(for: .seconds(error ? 8 : 4))
            if message?.text == text { message = nil }
        }
    }

    // MARK: Versions and shows

    func launch(_ build: MABuild) {
        if versions.contains(where: { $0.running?.build == build }) {
            flash("\(build.fullVersion) is already running"); return
        }
        let target: URL
        switch build.kind {
        case .parallels(let app, let vm, let exe):
            if build.cleanStart {
                // Parallels only wraps the plain exe, so CleanStart is started in the VM the way its shortcut does.
                let dir = Parallels.ma2Data + "\\gma2_V_\(build.dataVersion)"
                flash("Launching \(build.name)")
                Task.detached {
                    Parallels.launch(vm: vm, exe: exe, args: ["CLEANSTART", "NOLOAD"], workingDir: dir)
                    Parallels.invalidate()
                    await MainActor.run { self.refresh() }
                }
                return
            }
            target = app
        case .app(let url), .crossover(let url):
            target = url
        case .launcherSlot(let launcher, let slot):
            // The launcher starts whatever current_version names, same as MA's own version switch.
            let file = launcher.appendingPathComponent("Contents/MacOS/current_version")
            do { try slot.write(to: file, atomically: false, encoding: .utf8) }
            catch { flash("Couldn't select \(slot) in the grandMA3 launcher: \(error.localizedDescription)", error: true); return }
            target = launcher
        }
        NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in
                if let error { self.flash(error.localizedDescription, error: true) }
                else {
                    let other = self.versions.first { $0.isRunning }
                    self.flash("Launching \(build.name)" + (other.map { " (\($0.running!.build.fullVersion) is also running)" } ?? ""))
                }
                self.refresh()
            }
        }
    }

    func load(_ show: ShowFile, in v: MAVersion) {
        let name = show.name.replacingOccurrences(of: "\"", with: "")
        Task {
            do {
                try await OSC.send("/cmd", "LoadShow \"\(name)\"")
                flash("Sent LoadShow \"\(name)\" to \(v.version). Confirm on the console if it asks.")
            } catch {
                flash(error.localizedDescription, error: true)
            }
        }
    }

    func openFolder(_ v: MAVersion) {
        if let dir = v.winDir {
            let shows = ParallelsRef(vm: dir.vm, path: dir.path + "\\shows")
            Task.detached { Parallels.reveal(shows, select: false) }
            flash("Opening the shows folder in Windows Explorer")
            return
        }
        NSWorkspace.shared.open(v.showsDir)
    }

    /// Shows in Finder, or in Explorer inside the VM for shows read through prlctl.
    func revealShows(_ shows: [ShowFile]) {
        if let ref = shows.first?.remote {
            Task.detached { Parallels.reveal(ref, select: true) }
            flash("Showing \(shows[0].name) in Windows Explorer")
            return
        }
        reveal(shows.map(\.url))
    }

    func duplicate(_ show: ShowFile) {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmm"
        let dest = show.url.deletingLastPathComponent()
            .appendingPathComponent("\(show.name)_copy_\(f.string(from: Date()))\(show.fileExtension)")
        if let ref = show.remote {
            let name = dest.lastPathComponent
            Task.detached {
                let err = Parallels.copy(ref, toName: name)
                await MainActor.run {
                    if let err { self.flash(err, error: true) } else { self.flash("Copied to \(name)") }
                    self.refresh()
                }
            }
            return
        }
        do {
            try FileManager.default.copyItem(at: show.url, to: dest)
            flash("Copied to \(dest.lastPathComponent)")
        } catch {
            flash(error.localizedDescription, error: true)
        }
        refresh()
    }

    // MARK: Installing

    func install(_ pkg: InstallerPackage) {
        guard installing[pkg.url] == nil else { return }
        installing[pkg.url] = "Preparing…"
        Task.detached {
            let result = await Installer.install(pkg) { status in
                Task { @MainActor in self.installing[pkg.url] = status }
            }
            await MainActor.run {
                self.installing[pkg.url] = nil
                switch result {
                case .success: self.flash("Installed grandMA3 onPC \(pkg.version)")
                case .failure(let e): self.flash(e.localizedDescription, error: true)
                }
                self.refresh()
            }
        }
    }

    func openInInstaller(_ pkg: InstallerPackage) {
        if pkg.url.pathExtension.lowercased() == "pkg" { NSWorkspace.shared.open(pkg.url); return }
        installing[pkg.url] = "Extracting…"
        Task.detached {
            let pkgURL = Installer.extract(pkg.url)
            await MainActor.run {
                self.installing[pkg.url] = nil
                if let pkgURL { NSWorkspace.shared.open(pkgURL) }
                else { self.flash("No .pkg found in \(pkg.url.lastPathComponent)", error: true) }
            }
        }
    }

    func addInstallers(_ urls: [URL]) {
        let ok = urls.filter { InstallerScanner.isInstaller($0) }
        guard !ok.isEmpty else { flash("Not a grandMA3 onPC mac installer (.zip or .pkg)", error: true); return }
        do {
            let n = try LibraryFiles.importFiles(ok, into: InstallerScanner.packagesDir)
            flash("Added \(n) installer\(n == 1 ? "" : "s")")
        } catch { flash(error.localizedDescription, error: true) }
        refresh()
    }

    // MARK: Library files

    func importFiles(extensions: [String], into dir: URL) {
        let urls = LibraryFiles.chooseFiles(extensions: extensions, prompt: "Import")
        guard !urls.isEmpty else { return }
        importDropped(urls, extensions: extensions, into: dir)
    }

    func importDropped(_ urls: [URL], extensions: [String]?, into dir: URL) {
        let ok = extensions.map { exts in urls.filter { exts.contains($0.pathExtension.lowercased()) } } ?? urls
        guard !ok.isEmpty else {
            flash("Only \((extensions ?? []).map { "." + $0 }.joined(separator: ", ")) files", error: true); return
        }
        do {
            let n = try LibraryFiles.importFiles(ok, into: dir)
            flash("Imported \(n) item\(n == 1 ? "" : "s")")
        } catch { flash(error.localizedDescription, error: true) }
        refreshLibrary()
    }

    func duplicateLibraryFile(_ url: URL) {
        do { flash("Created \(try LibraryFiles.duplicate(url).lastPathComponent)") }
        catch { flash(error.localizedDescription, error: true) }
        refreshLibrary()
    }

    func copy(_ urls: [URL], to lib: LibraryLocation, subfolder: String) {
        do {
            let n = try LibraryFiles.importFiles(urls, into: lib.url.appendingPathComponent(subfolder))
            flash("Copied \(n) to \(lib.label)")
        } catch { flash(error.localizedDescription, error: true) }
    }

    func trash(_ urls: [URL]) {
        guard !urls.isEmpty, LibraryFiles.confirmTrash(urls.map { $0.lastPathComponent }) else { return }
        do {
            for u in urls { try FileManager.default.trashItem(at: u, resultingItemURL: nil) }
            flash("Moved \(urls.count) to Trash")
        } catch { flash(error.localizedDescription, error: true) }
        refreshLibrary()
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
