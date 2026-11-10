import Foundation

/// A file or folder inside a Parallels VM, by its Windows path.
struct ParallelsRef: Hashable {
    let vm: String
    let path: String
}

/// grandMA2 onPC inside Parallels Desktop VMs.
///
/// Parallels makes one wrapper app per Windows program in "~/Applications (Parallels)/{vm} Applications.localized/".
/// The bundles have hashed names; the target is in Contents/Resources/AppParams.pva ("APP Path = C:\…\gma2onpc.exe").
/// Everything else (running state, showfiles, CleanStart, duplicating, opening Explorer) goes through
/// `prlctl exec`, so it works without "Access Windows folders from Mac". When that drive is mounted in /Volumes,
/// the scanner uses the real files instead, which also lets Cloud Sync include them.
enum Parallels {
    static let appsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications (Parallels)")
    static let prlctl = [ProcessInfo.processInfo.environment["PRLCTL"] ?? "", "/usr/local/bin/prlctl",
                         "/Applications/Parallels Desktop.app/Contents/MacOS/prlctl"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    static let ma2Data = #"C:\ProgramData\MA Lighting Technologies\grandma"#

    /// prlctl prints VM ids without braces; wrapper folders and AppParams.pva use braces.
    static func norm(_ id: String) -> String {
        id.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).lowercased()
    }

    struct Wrapper {
        let url: URL
        let vm: String
        let vmName: String
        let exe: String
        /// "grandMA2 onPC 3.9.63.11", the exe's folder.
        var folder: String { exe.split(separator: "\\").dropLast().last.map(String.init) ?? "" }
    }

    static func wrappers() -> [Wrapper] {
        let fm = FileManager.default
        var out: [Wrapper] = []
        for vmDir in (try? fm.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil)) ?? [] {
            for app in (try? fm.contentsOfDirectory(at: vmDir, includingPropertiesForKeys: nil)) ?? []
            where app.pathExtension == "app" {
                guard let text = try? String(contentsOf: app.appendingPathComponent("Contents/Resources/AppParams.pva"),
                                             encoding: .utf8) else { continue }
                var params: [String: String] = [:]
                for line in text.split(whereSeparator: \.isNewline) {
                    let kv = line.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 { params[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1].trimmingCharacters(in: .whitespaces) }
                }
                guard let exe = params["APP Path"], let vm = params["VM Id"] else { continue }
                out.append(Wrapper(url: app, vm: norm(vm), vmName: params["VM Name"] ?? "Parallels VM", exe: exe))
            }
        }
        return out
    }

    // MARK: Querying running VMs

    struct RemoteShow { let version: String; let size: Int64; let mtime: Double; let name: String }
    struct VMState {
        var procs: [(pid: Int32, path: String)] = []
        var versions: Set<String> = []
        var shows: [RemoteShow] = []
        var ok = false
    }

    private static var cache: (at: Date, vms: [String: VMState]) = (.distantPast, [:])
    private static let lock = NSLock()

    static func invalidate() { lock.lock(); cache.at = .distantPast; lock.unlock() }

    /// One PowerShell call per running VM lists gma2onpc processes, gma2_V_ folders and their shows.
    /// PowerShell takes about a second to start, so the result is cached for 10 seconds.
    /// A VM that isn't running, or a Parallels edition without `prlctl exec`, just has no entry.
    static func query() -> [String: VMState] {
        guard let prlctl else { return [:] }
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(cache.at) < 10 { return cache.vms }
        struct VM: Decodable { let uuid: String; let status: String }
        let json = Scanner.shell(prlctl, ["list", "--json"], timeout: 5)
        let vms = (try? JSONDecoder().decode([VM].self, from: Data(json.utf8))) ?? []
        let script = """
        Get-Process gma2onpc -ErrorAction SilentlyContinue | ForEach-Object { "P|$($_.Id)|$($_.Path)" }
        Get-ChildItem -LiteralPath \(ps(ma2Data)) -Directory -Filter 'gma2_V_*' -ErrorAction SilentlyContinue | ForEach-Object {
          $v = $_.Name.Substring(7); "D|$v"
          Get-ChildItem -LiteralPath (Join-Path $_.FullName 'shows') -File -ErrorAction SilentlyContinue | ForEach-Object {
            "F|$v|$($_.Length)|$([DateTimeOffset]::new($_.LastWriteTimeUtc).ToUnixTimeSeconds())|$($_.Name)" }
        }
        "OK"
        """
        var out: [String: VMState] = [:]
        for vm in vms where vm.status == "running" {
            var st = VMState()
            for line in run(vm: vm.uuid, script, timeout: 8).split(whereSeparator: \.isNewline) {
                let f = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
                switch f.first {
                case "P" where f.count >= 3: if let pid = Int32(f[1]) { st.procs.append((pid, f[2...].joined(separator: "|"))) }
                case "D" where f.count == 2: st.versions.insert(f[1])
                case "F" where f.count == 5:
                    st.shows.append(RemoteShow(version: f[1], size: Int64(f[2]) ?? 0, mtime: Double(f[3]) ?? 0, name: f[4]))
                case "OK": st.ok = true
                default: break
                }
            }
            if st.ok { out[norm(vm.uuid)] = st }
        }
        cache = (Date(), out)
        return out
    }

    // MARK: Running things in the VM

    /// A PowerShell single-quoted string literal.
    static func ps(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

    /// Runs a PowerShell script in the VM. It's sent base64-encoded because `prlctl exec` drops double quotes.
    /// `asUser` runs it in the logged-in user's session, so windows it opens are visible.
    @discardableResult
    static func run(vm: String, _ script: String, asUser: Bool = false, timeout: TimeInterval = 15) -> String {
        guard let prlctl else { return "" }
        let full = "$ProgressPreference = 'SilentlyContinue'\n" + script
        var utf16 = Data()
        for u in full.utf16 { utf16.append(UInt8(u & 0xff)); utf16.append(UInt8(u >> 8)) }
        var args = ["exec", vm]
        if asUser { args.append("--current-user") }
        args += ["powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand", utf16.base64EncodedString()]
        return Scanner.shell(prlctl, args, timeout: timeout)
    }

    static func launch(vm: String, exe: String, args: [String], workingDir: String?) {
        var cmd = "Start-Process -FilePath \(ps(exe))"
        if !args.isEmpty { cmd += " -ArgumentList " + args.map(ps).joined(separator: ",") }
        if let workingDir { cmd += " -WorkingDirectory \(ps(workingDir))" }
        run(vm: vm, cmd, asUser: true)
    }

    /// Opens Explorer in the VM on a folder, or with a file selected.
    static func reveal(_ ref: ParallelsRef, select: Bool) {
        let arg = select ? "/select,\"\(ref.path)\"" : "\"\(ref.path)\""
        run(vm: ref.vm, "Start-Process explorer.exe -ArgumentList \(ps(arg))", asUser: true)
    }

    /// Copies a file next to itself; returns an error message, or nil.
    static func copy(_ ref: ParallelsRef, toName name: String) -> String? {
        let dest = ref.path.split(separator: "\\").dropLast().joined(separator: "\\") + "\\" + name
        let out = run(vm: ref.vm, """
            try { Copy-Item -LiteralPath \(ps(ref.path)) -Destination \(ps(dest)) -ErrorAction Stop; "DONE" }
            catch { "ERR " + $_.Exception.Message }
            """, asUser: true)
        invalidate()
        if out.contains("DONE") { return nil }
        return out.split(whereSeparator: \.isNewline).first { $0.hasPrefix("ERR ") }.map { String($0.dropFirst(4)) }
            ?? "Couldn't copy the file inside the VM"
    }
}
