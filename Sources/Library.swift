import AppKit
import Foundation
import SwiftUI

/// A grandMA3 user library folder (gma3_library), either the shared one or a per-version one.
struct LibraryLocation: Identifiable, Hashable {
    let url: URL
    let label: String
    var id: URL { url }
    var themesDir: URL { url.appendingPathComponent("colorthemes") }
    var fixturesDir: URL { url.appendingPathComponent("fixturetypes") }
    var datapoolsDir: URL { url.appendingPathComponent("datapools") }

    static func all() -> [LibraryLocation] {
        let fm = FileManager.default
        var out: [LibraryLocation] = []
        let shared = Scanner.maRoot.appendingPathComponent("gma3_library")
        if fm.fileExists(atPath: shared.path) { out.append(.init(url: shared, label: "Shared library")) }
        let dirs = ((try? fm.contentsOfDirectory(atPath: Scanner.maRoot.path)) ?? [])
            .filter { $0.hasPrefix("gma3_") && $0 != "gma3_library" }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for d in dirs {
            let lib = Scanner.maRoot.appendingPathComponent(d).appendingPathComponent("gma3_library")
            if fm.fileExists(atPath: lib.path) { out.append(.init(url: lib, label: "v\(d.dropFirst(5)) library")) }
        }
        return out
    }
}

// MARK: - Color themes

struct ThemeColor: Hashable {
    let name: String
    let rgba: String
    var color: Color { Color(hexRGBA: rgba) }
}

struct ColorTheme: Identifiable, Hashable {
    let url: URL
    let dataVersion: String
    let groups: [(name: String, colors: [ThemeColor])]
    let modified: Date
    var id: URL { url }
    var name: String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "theme_", with: "")
    }
    var colorCount: Int { groups.reduce(0) { $0 + $1.colors.count } }

    func color(_ name: String, group: String = "Global") -> Color {
        let g = groups.first { $0.name == group } ?? groups.first
        return g?.colors.first { $0.name == name }?.color ?? .gray
    }

    static func == (a: ColorTheme, b: ColorTheme) -> Bool { a.url == b.url && a.modified == b.modified }
    func hash(into h: inout Hasher) { h.combine(url); h.combine(modified) }
}

private final class ThemeParser: NSObject, XMLParserDelegate {
    var dataVersion = ""
    var groups: [(name: String, colors: [ThemeColor])] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String]) {
        switch name {
        case "GMA3": dataVersion = a["DataVersion"] ?? ""
        case "ColorDefGroup": groups.append((a["Name"] ?? "?", []))
        case "ColorDef":
            if let n = a["Name"], let c = a["RGBA"], !groups.isEmpty {
                groups[groups.count - 1].colors.append(ThemeColor(name: n, rgba: c))
            }
        default: break
        }
    }
}

enum ThemeScanner {
    static func scan(_ dir: URL) -> [ColorTheme] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "xml" }.compactMap(parse)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func parse(_ url: URL) -> ColorTheme? {
        guard let parser = XMLParser(contentsOf: url) else { return nil }
        let d = ThemeParser()
        parser.delegate = d
        parser.parse()
        guard !d.groups.isEmpty else { return nil }
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return ColorTheme(url: url, dataVersion: d.dataVersion, groups: d.groups, modified: mod)
    }
}

extension Color {
    init(hexRGBA s: String) {
        let v = UInt64(s.prefix(8), radix: 16) ?? 0
        let has8 = s.count >= 8
        let r = Double((v >> (has8 ? 24 : 16)) & 0xFF) / 255
        let g = Double((v >> (has8 ? 16 : 8)) & 0xFF) / 255
        let b = Double((v >> (has8 ? 8 : 0)) & 0xFF) / 255
        let a = has8 ? Double(v & 0xFF) / 255 : 1
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Fixture types

enum FixtureFormat: String, CaseIterable, Identifiable {
    case gdtf = "GDTF", ma3 = "MA3 XML", ma2 = "MA2 pxml"
    var id: String { rawValue }
}

struct FixtureMode: Hashable {
    let name: String
    let channels: Int
}

struct FixtureType: Identifiable, Hashable {
    let url: URL
    let format: FixtureFormat
    let manufacturer: String
    let name: String
    let revision: String
    let modes: [FixtureMode]
    let size: Int64
    let modified: Date
    var id: URL { url }
    var fileName: String { url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent }
}

/// Reads the common GDTF / MA3 fixture type structure: FixtureType, DMXMode, DMXChannel, Revision.
private final class FixtureParser: NSObject, XMLParserDelegate {
    var name = "", manufacturer = "", revision = ""
    var modes: [FixtureMode] = []
    private var currentMode: String?
    private var channelCount = 0

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String]) {
        switch el {
        case "FixtureType" where name.isEmpty:
            name = a["Name"] ?? a["LongName"] ?? ""
            manufacturer = a["Manufacturer"] ?? ""
        case "Revision":
            if let t = a["Text"], !t.isEmpty { revision = t }
            else if let d = a["Date"] { revision = d }
        case "DMXMode":
            currentMode = a["Name"] ?? "Mode \(modes.count + 1)"
            channelCount = 0
        case "DMXChannel" where currentMode != nil:
            channelCount += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        if el == "DMXMode", let m = currentMode {
            modes.append(FixtureMode(name: m, channels: channelCount))
            currentMode = nil
        }
    }
}

enum FixtureScanner {
    private static var cache: [URL: (Date, FixtureType)] = [:]
    private static let lock = NSLock()

    static func scan(_ dir: URL) -> [FixtureType] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        return urls.compactMap { url -> FixtureType? in
            let ext = url.pathExtension.lowercased()
            let format: FixtureFormat
            switch ext {
            case "gdtf": format = .gdtf
            case "xml": format = .ma3
            case "pxml": format = .ma2
            default: return nil
            }
            let rv = try? url.resourceValues(forKeys: Set(keys))
            let mod = rv?.contentModificationDate ?? .distantPast
            lock.lock(); let hit = cache[url]; lock.unlock()
            if let hit, hit.0 == mod { return hit.1 }
            let ft = parse(url, format: format, size: Int64(rv?.fileSize ?? 0), modified: mod)
            lock.lock(); cache[url] = (mod, ft); lock.unlock()
            return ft
        }
        .sorted { [$0.manufacturer, $0.name].lexicographicallyPrecedes([$1.manufacturer, $1.name]) {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
    }

    static func parse(_ url: URL, format: FixtureFormat, size: Int64, modified: Date) -> FixtureType {
        var data: Data?
        switch format {
        case .gdtf: data = unzip(url, entry: "description.xml")
        case .ma3: data = try? Data(contentsOf: url)
        case .ma2: data = nil // compressed MA2 library format; filename only
        }
        let p = FixtureParser()
        if let data {
            let xml = XMLParser(data: data)
            xml.delegate = p
            xml.parse()
        }
        // Fall back to "Manufacturer@Name@Revision" filenames.
        let parts = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .removingPercentEncoding?.components(separatedBy: "@") ?? []
        return FixtureType(
            url: url, format: format,
            manufacturer: p.manufacturer.isEmpty ? (parts.first ?? "") : p.manufacturer,
            name: p.name.isEmpty ? (parts.count > 1 ? parts[1] : parts.first ?? url.lastPathComponent) : p.name,
            revision: p.revision.isEmpty && parts.count > 2 ? parts[2] : p.revision,
            modes: p.modes, size: size, modified: modified)
    }

    static func unzip(_ url: URL, entry: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-p", url.path, entry]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }
}

// MARK: - File operations shared by the library managers

enum LibraryFiles {
    /// Copies files into a library folder without overwriting; returns how many were copied.
    static func importFiles(_ urls: [URL], into dir: URL) throws -> Int {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var n = 0
        for src in urls {
            let dest = uniqueDestination(dir.appendingPathComponent(src.lastPathComponent))
            try FileManager.default.copyItem(at: src, to: dest)
            n += 1
        }
        return n
    }

    static func duplicate(_ url: URL, suffix: String = "copy") throws -> URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dest = uniqueDestination(url.deletingLastPathComponent().appendingPathComponent("\(base)_\(suffix).\(ext)"))
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            let c = url.deletingLastPathComponent().appendingPathComponent("\(base) \(i).\(ext)")
            if !fm.fileExists(atPath: c.path) { return c }
            i += 1
        }
    }

    static func chooseFiles(extensions: [String], prompt: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = prompt
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.filter { extensions.contains($0.pathExtension.lowercased()) }
    }

    static func confirmTrash(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? "Move “\(names[0])” to the Trash?" : "Move \(names.count) files to the Trash?"
        alert.informativeText = "You can restore it from the Trash in Finder."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

import UniformTypeIdentifiers

// MARK: - Datapools (presets, plugins, macros, sequences, …)

struct DatapoolItem: Identifiable, Hashable {
    let url: URL
    let isFolder: Bool
    let kind: String          // root element under <GMA3>, e.g. "Preset", "Plugin"; or the file type
    let name: String
    let dataVersion: String
    let attributes: [String: String]
    let components: [String]  // plugin ComponentLua file names
    let size: Int64
    let modified: Date
    var id: URL { url }
    var fileName: String { url.lastPathComponent }
    /// "Foo.lua.bak-1.2.0" style copies left behind by plugin development.
    var isBackup: Bool { fileName.range(of: #"\.bak(-|$)"#, options: .regularExpression) != nil }
    var detail: String {
        if let v = attributes["Version"] { return "v\(v)" + (attributes["Author"].map { " · \($0)" } ?? "") }
        if let m = attributes["PresetMode"] { return m }
        return ""
    }
}

struct Datapool: Identifiable, Hashable {
    let name: String
    let url: URL
    let items: [DatapoolItem]
    var id: String { name }
    var title: String {
        let special = ["executorconfigurations": "Executor Configurations", "executorpages": "Executor Pages",
                       "matricks": "MAtricks", "quickeys": "Quickeys", "timecodes": "Timecodes"]
        return special[name] ?? name.prefix(1).uppercased() + name.dropFirst()
    }
    var icon: String {
        switch name {
        case "presets": "square.grid.3x3.fill"
        case "plugins": "puzzlepiece.extension"
        case "macros": "text.alignleft"
        case "sequences": "list.number"
        case "groups": "circle.grid.cross"
        case "bitmaps": "photo"
        case "layouts": "rectangle.3.group"
        case "timecodes": "timer"
        case "timers": "stopwatch"
        case "worlds": "globe"
        case "filters": "line.3.horizontal.decrease.circle"
        case "generators": "waveform.path"
        case "matricks": "square.grid.4x3.fill"
        case "shapes": "triangle"
        case "quickeys": "keyboard"
        case "executorpages", "executorconfigurations": "slider.vertical.3"
        default: "folder"
        }
    }
}

/// Reads just the first object under <GMA3> (and a plugin's ComponentLua children), then stops.
private final class PoolItemParser: NSObject, XMLParserDelegate {
    var dataVersion = ""
    var kind = ""
    var attributes: [String: String] = [:]
    var components: [String] = []
    private var depth = 0

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String]) {
        depth += 1
        if el == "GMA3" { dataVersion = a["DataVersion"] ?? ""; return }
        if kind.isEmpty { kind = el; attributes = a; return }
        if kind == "Plugin", el == "ComponentLua", let f = a["FileName"] { components.append(f); return }
        if kind != "Plugin" { parser.abortParsing() }
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
        if el == kind && depth <= 1 { parser.abortParsing() }
    }
}

enum DatapoolScanner {
    static func scan(_ dir: URL) -> [Datapool] {
        let fm = FileManager.default
        let pools = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return pools.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { Datapool(name: $0.lastPathComponent, url: $0, items: items(in: $0)) }
            .sorted { $0.title < $1.title }
    }

    static func items(in pool: URL) -> [DatapoolItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: pool, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        return urls.filter { $0.lastPathComponent != "libcache.dat" }.map { url in
            let rv = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = rv?.isDirectory == true
            let mod = rv?.contentModificationDate ?? .distantPast
            // A folder (e.g. a plugin with its own files) is described by the first .xml inside it.
            let xml = isFolder
                ? ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                    .first { $0.pathExtension.lowercased() == "xml" }
                : (url.pathExtension.lowercased() == "xml" ? url : nil)
            let p = PoolItemParser()
            if let xml, let parser = XMLParser(contentsOf: xml) { parser.delegate = p; parser.parse() }
            let fallbackKind = isFolder ? "Folder" : url.pathExtension.isEmpty ? "File" : url.pathExtension.uppercased()
            return DatapoolItem(
                url: url, isFolder: isFolder,
                kind: p.kind.isEmpty ? fallbackKind : p.kind,
                name: p.attributes["Name"] ?? url.deletingPathExtension().lastPathComponent,
                dataVersion: p.dataVersion, attributes: p.attributes, components: p.components,
                size: isFolder ? folderSize(url) : Int64(rv?.fileSize ?? 0), modified: mod)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func folderSize(_ url: URL) -> Int64 {
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let f = e?.nextObject() as? URL { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }
}
