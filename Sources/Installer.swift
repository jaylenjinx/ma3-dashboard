import Foundation

/// A grandMA3 onPC macOS installer: MA's release zip (ma/*.pkg + release xml) or a bare .pkg.
struct InstallerPackage: Identifiable, Hashable {
    let url: URL
    let version: String
    let size: Int64
    let modified: Date
    var id: URL { url }
    var dataVersion: String { version.split(separator: ".").prefix(3).joined(separator: ".") }
}

enum InstallerScanner {
    static let packagesDir = Scanner.maRoot.appendingPathComponent("installation_packages")
    static let searchDirs = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
        packagesDir,
    ]

    static func version(of url: URL) -> String? {
        let name = url.lastPathComponent
        guard let r = name.range(of: #"v?(\d+\.\d+\.\d+(\.\d+)?)"#, options: .regularExpression) else { return nil }
        return String(name[r]).trimmingCharacters(in: CharacterSet(charactersIn: "v"))
    }

    static func isInstaller(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        guard ext == "zip" || ext == "pkg", n.contains("grandma3"), n.contains("onpc") else { return false }
        // Skip Windows/Linux builds and console full packages.
        return !n.contains("_win") && !n.contains("linux") && version(of: url) != nil
    }

    static func scan() -> [InstallerPackage] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        var seen = Set<String>()
        return searchDirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? [])
                .filter(isInstaller)
        }
        .compactMap { url -> InstallerPackage? in
            guard seen.insert(url.lastPathComponent).inserted, let v = version(of: url) else { return nil }
            let rv = try? url.resourceValues(forKeys: Set(keys))
            return InstallerPackage(url: url, version: v, size: Int64(rv?.fileSize ?? 0),
                                    modified: rv?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }
}

enum Installer {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Unzips an MA release zip into a scratch folder and returns the .pkg inside (or the .pkg itself).
    static func extract(_ url: URL) -> URL? { extractToScratch(url)?.pkg }

    private static func extractToScratch(_ url: URL) -> (pkg: URL, scratch: URL?)? {
        if url.pathExtension.lowercased() == "pkg" { return (url, nil) }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("MA3Dashboard-\(UUID().uuidString)")
        var status: Int32 = 0
        Scanner.shell("/usr/bin/ditto", ["-x", "-k", url.path, dest.path], status: &status)
        let e = FileManager.default.enumerator(at: dest, includingPropertiesForKeys: nil)
        while status == 0, let f = e?.nextObject() as? URL {
            if f.pathExtension.lowercased() == "pkg" { return (f, dest) }
        }
        try? FileManager.default.removeItem(at: dest)
        return nil
    }

    /// Runs Apple's `installer` with the standard macOS admin prompt.
    static func install(_ pkg: InstallerPackage, progress: @escaping (String) -> Void) async -> Result<Void, Error> {
        progress(pkg.url.pathExtension.lowercased() == "zip" ? "Extracting…" : "Preparing…")
        guard let (pkgURL, scratch) = extractToScratch(pkg.url) else {
            return .failure(Failure(message: "No .pkg found in \(pkg.url.lastPathComponent)"))
        }
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        progress("Installing… (enter your password)")
        let script = """
        on run argv
            do shell script "/usr/sbin/installer -pkg " & quoted form of (item 1 of argv) & " -target /" with administrator privileges
        end run
        """
        var status: Int32 = 0
        let out = Scanner.shell("/usr/bin/osascript", ["-e", script, pkgURL.path], status: &status)
        if status != 0 {
            let msg = out.contains("User canceled") || out.contains("-128") ? "Install cancelled" : "Install failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))"
            return .failure(Failure(message: msg))
        }
        return .success(())
    }
}
