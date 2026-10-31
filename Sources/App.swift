import AppKit
import SwiftUI

enum SidebarItem: Hashable, RawRepresentable {
    case version(String), themes, fixtures, datapools, install, sync

    init?(rawValue: String) {
        switch rawValue {
        case "themes": self = .themes
        case "fixtures": self = .fixtures
        case "datapools": self = .datapools
        case "install": self = .install
        case "sync": self = .sync
        case let s where s.hasPrefix("v:"): self = .version(String(s.dropFirst(2)))
        default: return nil
        }
    }
    var rawValue: String {
        switch self {
        case .version(let v): return "v:\(v)"
        case .themes: return "themes"
        case .fixtures: return "fixtures"
        case .datapools: return "datapools"
        case .install: return "install"
        case .sync: return "sync"
        }
    }
}

@main
struct MA3DashboardApp: App {
    @State private var store = Store()

    init() {
        HeadlessSync.runIfRequested()
        // Running as a bare SwiftPM executable still gets a Dock icon and focus.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("MA3 Dashboard", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 520)
                .task { store.start(); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { store.refresh(); store.refreshLibrary() }
                    .keyboardShortcut("r")
            }
        }
    }
}

struct ContentView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(selection: $store.selection) {
                Section("grandMA3 onPC") {
                    ForEach(store.versions.filter { $0.product == .ma3 }) { v in
                        VersionRow(v: v).tag(SidebarItem.version(v.id))
                    }
                }
                let ma2 = store.versions.filter { $0.product == .ma2 }
                if !ma2.isEmpty {
                    Section("grandMA2 onPC · CrossOver") {
                        ForEach(ma2) { v in VersionRow(v: v).tag(SidebarItem.version(v.id)) }
                    }
                }
                Section("Library") {
                    Label {
                        HStack { Text("Color Themes"); Spacer(); Text("\(store.themes.count)").foregroundStyle(.secondary) }
                    } icon: { Image(systemName: "paintpalette") }
                    .tag(SidebarItem.themes)
                    Label {
                        HStack { Text("Fixture Types"); Spacer(); Text("\(store.fixtures.count)").foregroundStyle(.secondary) }
                    } icon: { Image(systemName: "lightspectrum.horizontal") }
                    .tag(SidebarItem.fixtures)
                    SidebarCountRow(title: "Datapools", icon: "tray.full",
                                    count: store.pools.reduce(0) { $0 + $1.items.filter { !$0.isBackup }.count })
                        .tag(SidebarItem.datapools)
                }
                Section("Software") {
                    let new = store.installers.filter { p in !store.allBuilds.contains { $0.fullVersion == p.version } }.count
                    SidebarCountRow(title: "Install Versions", icon: "arrow.down.app", count: new, highlight: new > 0)
                        .tag(SidebarItem.install)
                    SyncSidebarRow().tag(SidebarItem.sync)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            switch store.selection {
            case .version:
                if let v = store.selected { ShowsView(v: v) } else { ContentUnavailableView("Pick a version", systemImage: "sidebar.left") }
            case .themes: ThemesView()
            case .fixtures: FixturesView()
            case .datapools: DatapoolsView()
            case .install: InstallView()
            case .sync: SyncView()
            case nil: ContentUnavailableView("Pick a version", systemImage: "sidebar.left")
            }
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                HStack(spacing: 6) {
                    StatusDot(on: store.oscListening)
                    Text("OSC 8000").font(.caption).foregroundStyle(.secondary)
                }
                .help("Whether a running onPC is listening for OSC on UDP 8000")
            }
        }
        .overlay(alignment: .bottom) {
            if let m = store.message {
                Text(m.text)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(m.isError ? Color.red : Color.clear))
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.message?.text)
    }
}

struct StatusDot: View {
    let on: Bool
    var body: some View {
        Circle().fill(on ? Color.green : Color.secondary.opacity(0.4))
            .frame(width: 8, height: 8)
            .shadow(color: on ? .green : .clear, radius: 3)
    }
}

struct SidebarCountRow: View {
    let title: String
    let icon: String
    let count: Int
    var highlight = false
    var body: some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                if highlight {
                    Text("\(count) new").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.25), in: Capsule())
                } else if count > 0 {
                    Text("\(count)").foregroundStyle(.secondary)
                }
            }
        } icon: { Image(systemName: icon) }
    }
}

struct VersionRow: View {
    let v: MAVersion
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(v.version).font(.headline).monospacedDigit()
                Spacer()
                StatusDot(on: v.isRunning)
                Text(v.isRunning ? "Running" : v.builds.isEmpty ? "Not installed" : "Stopped")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(v.shows.count) shows" + (v.backupCount > 0 ? " · \(v.backupCount) backups" : "")
                 + (v.builds.count > 1 ? " · \(v.builds.count) builds" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Showfiles

struct ShowsView: View {
    @Environment(Store.self) private var store
    let v: MAVersion
    @State private var query = ""
    @State private var sortOrder = [KeyPathComparator(\ShowFile.modified, order: .reverse)]
    @State private var selection = Set<ShowFile.ID>()

    var canLoad: Bool { v.product == .ma3 && v.isRunning && store.oscListening }

    var rows: [ShowFile] {
        v.shows.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Show", value: \.name) { s in Text(s.name).fontWeight(.medium) }
            TableColumn("Modified", value: \.modified) { s in
                Text(s.modified, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 140, ideal: 160)
            TableColumn("Size", value: \.size) { s in
                Text(ByteCountFormatter.string(fromByteCount: s.size, countStyle: .file))
                    .foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 80)
        }
        .contextMenu(forSelectionType: ShowFile.ID.self) { ids in
            let shows = v.shows.filter { ids.contains($0.id) }
            if let s = shows.first, shows.count == 1 {
                if v.product == .ma3 { Button("Load in \(v.version)") { confirmLoad(s) }.disabled(!canLoad) }
                Button("Duplicate") { store.duplicate(s) }
            }
            Button("Show in Finder") { store.reveal(shows.map(\.url)) }
        } primaryAction: { ids in
            guard let s = v.shows.first(where: { ids.contains($0.id) }) else { return }
            if canLoad { confirmLoad(s) } else { store.reveal([s.url]) }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(v.shows.isEmpty ? "No showfiles" : "No matches",
                                       systemImage: "doc", description: Text(v.shows.isEmpty ? v.showsDir.path : ""))
            }
        }
        .searchable(text: $query, prompt: "Filter showfiles")
        .navigationTitle("\(v.product.title) \(v.version)")
        .navigationSubtitle(v.running.map { "Running \($0.build.fullVersion) · PID \($0.pid)" }
                            ?? (v.builds.isEmpty ? "No build installed" : v.builds.map(\.fullVersion).joined(separator: ", ")))
        .toolbar {
            ToolbarItemGroup {
                Button { store.openFolder(v) } label: { Label("Shows Folder", systemImage: "folder") }
                    .help("Open the shows folder in Finder")
                if v.product == .ma3, let s = v.shows.first(where: { selection.contains($0.id) }) {
                    Button { confirmLoad(s) } label: { Label("Load Show", systemImage: "square.and.arrow.down") }
                        .disabled(!canLoad)
                        .help(canLoad ? "Send LoadShow over OSC" : "Needs this version running with OSC input enabled")
                }
                if v.builds.count > 1 && !v.isRunning {
                    Menu {
                        ForEach(v.builds) { b in Button("Launch \(b.name)") { store.launch(b) } }
                    } label: {
                        Label("Launch \(v.newestBuild!.fullVersion)", systemImage: "play.fill").labelStyle(.titleAndIcon)
                    } primaryAction: {
                        store.launch(v.newestBuild!)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                    .help("Click to launch the newest build; use the arrow to pick another")
                } else {
                    Button { if let b = v.newestBuild { store.launch(b) } } label: {
                        Label(v.isRunning ? "Running" : "Launch", systemImage: v.isRunning ? "checkmark.circle.fill" : "play.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(v.builds.isEmpty || v.isRunning)
                }
            }
        }
    }

    func confirmLoad(_ s: ShowFile) {
        let alert = NSAlert()
        alert.messageText = "Load “\(s.name)” into the running \(v.version)?"
        alert.informativeText = "Unsaved changes in the current show may be lost."
        alert.addButton(withTitle: "Load")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.load(s, in: v) }
    }
}

// MARK: - Library picker shared by the managers

struct LibraryPicker: View {
    @Environment(Store.self) private var store
    var body: some View {
        @Bindable var store = store
        if store.libraries.count > 1 {
            Picker("Library", selection: Binding(get: { store.library?.url }, set: { store.libraryURL = $0 })) {
                ForEach(store.libraries) { Text($0.label).tag(Optional($0.url)) }
            }
            .fixedSize()
        }
    }
}

struct CopyToLibraryMenu: View {
    @Environment(Store.self) private var store
    let urls: [URL]
    let subfolder: String
    var body: some View {
        let others = store.libraries.filter { $0.url != store.library?.url }
        if !others.isEmpty {
            Menu("Copy to") {
                ForEach(others) { lib in Button(lib.label) { store.copy(urls, to: lib, subfolder: subfolder) } }
            }
        }
    }
}

// MARK: - Color themes

struct ThemesView: View {
    @Environment(Store.self) private var store
    @State private var selected: ColorTheme.ID?
    @State private var query = ""
    @State private var dropTarget = false

    var theme: ColorTheme? { store.themes.first { $0.id == selected } }
    var rows: [ColorTheme] { store.themes.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                ForEach(rows) { t in
                    ThemeCard(theme: t, selected: t.id == selected)
                        .onTapGesture { selected = t.id }
                        .contextMenu { themeMenu(t) }
                }
            }
            .padding(20)
        }
        .overlay {
            if store.themes.isEmpty && !store.loadingLibrary {
                ContentUnavailableView("No color themes", systemImage: "paintpalette",
                                       description: Text("Import a theme .xml or drop one here."))
            }
        }
        .background(dropTarget ? Color.accentColor.opacity(0.08) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let lib = store.library else { return false }
            store.importDropped(urls, extensions: ["xml"], into: lib.themesDir)
            return true
        } isTargeted: { dropTarget = $0 }
        .searchable(text: $query, prompt: "Filter themes")
        .navigationTitle("Color Themes")
        .navigationSubtitle(store.library?.themesDir.path ?? "")
        .inspector(isPresented: Binding(get: { theme != nil }, set: { if !$0 { selected = nil } })) {
            if let theme { ThemeDetail(theme: theme).inspectorColumnWidth(min: 280, ideal: 320) }
        }
        .toolbar {
            ToolbarItemGroup {
                LibraryPicker()
                Button {
                    if let lib = store.library { NSWorkspace.shared.open(lib.themesDir) }
                } label: { Label("Themes Folder", systemImage: "folder") }
                Button {
                    if let lib = store.library { store.importFiles(extensions: ["xml"], into: lib.themesDir) }
                } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .help("Copy color theme .xml files into this library")
            }
        }
    }

    @ViewBuilder func themeMenu(_ t: ColorTheme) -> some View {
        Button("Duplicate") { store.duplicateLibraryFile(t.url) }
        Button("Show in Finder") { store.reveal([t.url]) }
        CopyToLibraryMenu(urls: [t.url], subfolder: "colorthemes")
        Divider()
        Button("Move to Trash", role: .destructive) {
            if selected == t.id { selected = nil }
            store.trash([t.url])
        }
    }
}

/// A miniature mock of an MA3 window drawn in the theme's own colors.
struct ThemeCard: View {
    let theme: ColorTheme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                Color.black
                theme.color("BackgroundDark")
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Text("Sequence").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.color("Text"))
                        Spacer()
                        Circle().fill(theme.color("Selected")).frame(width: 7, height: 7)
                    }
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(theme.color("Header"))
                    ForEach(0..<4) { i in
                        HStack {
                            Text("Cue \(i + 1)").font(.system(size: 9))
                                .foregroundStyle(i == 1 ? theme.color("TextDark") : theme.color("Text"))
                            Spacer()
                        }
                        .padding(.horizontal, 8).frame(height: 15)
                        .background(i == 1 ? theme.color("Selected")
                                    : theme.color(i.isMultiple(of: 2) ? "DefaultCellBackground" : "DefaultCellAltBackground"))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            HStack {
                Text(theme.name).font(.headline).lineLimit(1)
                Spacer()
                Text(theme.dataVersion).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 3) {
                ForEach(["Text", "Header", "Selected", "SelectedInverted", "InvalidGridPosition", "PartlySelected"], id: \.self) {
                    RoundedRectangle(cornerRadius: 2).fill(theme.color($0)).frame(height: 8)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

struct ThemeDetail: View {
    @Environment(Store.self) private var store
    let theme: ColorTheme
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(theme.name).font(.title2.bold())
                Text("\(theme.colorCount) colors · \(theme.groups.count) groups · DataVersion \(theme.dataVersion)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(theme.url.lastPathComponent).font(.caption).foregroundStyle(.tertiary)
                TextField("Filter colors", text: $query).textFieldStyle(.roundedBorder).padding(.top, 6)
            }
            .padding()
            List {
                ForEach(theme.groups, id: \.name) { g in
                    let colors = g.colors.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
                    if !colors.isEmpty {
                        Section(g.name) {
                            ForEach(colors, id: \.name) { c in
                                HStack {
                                    ZStack {
                                        // Checkerboard-ish base so transparency is visible.
                                        RoundedRectangle(cornerRadius: 3).fill(.white)
                                        RoundedRectangle(cornerRadius: 3).fill(c.color)
                                    }
                                    .frame(width: 28, height: 16)
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.separator))
                                    Text(c.name).lineLimit(1)
                                    Spacer()
                                    Text(c.rgba).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Fixture types

struct FixturesView: View {
    @Environment(Store.self) private var store
    @State private var query = ""
    @State private var format: FixtureFormat?
    @State private var selection = Set<FixtureType.ID>()
    @State private var sortOrder = [KeyPathComparator(\FixtureType.manufacturer)]
    @State private var dropTarget = false

    static let extensions = ["gdtf", "xml", "pxml"]

    var rows: [FixtureType] {
        store.fixtures.filter { f in
            (format == nil || f.format == format) &&
                (query.isEmpty || f.name.localizedCaseInsensitiveContains(query)
                    || f.manufacturer.localizedCaseInsensitiveContains(query)
                    || f.fileName.localizedCaseInsensitiveContains(query))
        }
        .sorted(using: sortOrder)
    }
    var selectedTypes: [FixtureType] { store.fixtures.filter { selection.contains($0.id) } }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Manufacturer", value: \.manufacturer).width(min: 100, ideal: 150)
            TableColumn("Name", value: \.name) { f in Text(f.name).fontWeight(.medium) }.width(min: 140, ideal: 220)
            TableColumn("Format", value: \.format.rawValue) { f in FormatBadge(format: f.format) }.width(80)
            TableColumn("Modes", value: \.modes.count) { f in
                Text(f.modes.isEmpty ? "—" : "\(f.modes.count)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(50)
            TableColumn("Revision", value: \.revision) { f in Text(f.revision).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 80, ideal: 140)
            TableColumn("Modified", value: \.modified) { f in
                Text(f.modified, format: .dateTime.day().month(.abbreviated).year()).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 100)
            TableColumn("Size", value: \.size) { f in
                Text(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                    .foregroundStyle(.secondary).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(70)
        }
        .contextMenu(forSelectionType: FixtureType.ID.self) { ids in
            let urls = store.fixtures.filter { ids.contains($0.id) }.map(\.url)
            if urls.count == 1 { Button("Duplicate") { store.duplicateLibraryFile(urls[0]) } }
            Button("Show in Finder") { store.reveal(urls) }
            CopyToLibraryMenu(urls: urls, subfolder: "fixturetypes")
            Divider()
            Button("Move to Trash", role: .destructive) { selection.subtract(ids); store.trash(urls) }
        } primaryAction: { ids in
            store.reveal(store.fixtures.filter { ids.contains($0.id) }.map(\.url))
        }
        .overlay {
            if store.loadingLibrary && store.fixtures.isEmpty { ProgressView("Reading fixture types…") }
            else if rows.isEmpty {
                ContentUnavailableView(store.fixtures.isEmpty ? "No fixture types" : "No matches",
                                       systemImage: "lightspectrum.horizontal",
                                       description: Text(store.fixtures.isEmpty ? "Import .gdtf or MA3 .xml files, or drop them here." : ""))
            }
        }
        .background(dropTarget ? Color.accentColor.opacity(0.08) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let lib = store.library else { return false }
            store.importDropped(urls, extensions: Self.extensions, into: lib.fixturesDir)
            return true
        } isTargeted: { dropTarget = $0 }
        .searchable(text: $query, prompt: "Filter fixture types")
        .navigationTitle("Fixture Types")
        .navigationSubtitle(store.library?.fixturesDir.path ?? "")
        .inspector(isPresented: Binding(get: { selectedTypes.count == 1 }, set: { if !$0 { selection = [] } })) {
            if let f = selectedTypes.first, selectedTypes.count == 1 {
                FixtureDetail(f: f).inspectorColumnWidth(min: 260, ideal: 300)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Format", selection: $format) {
                    Text("All").tag(FixtureFormat?.none)
                    ForEach(FixtureFormat.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                LibraryPicker()
                Button {
                    if let lib = store.library { NSWorkspace.shared.open(lib.fixturesDir) }
                } label: { Label("Fixture Types Folder", systemImage: "folder") }
                Button {
                    if let lib = store.library { store.importFiles(extensions: Self.extensions, into: lib.fixturesDir) }
                } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .help("Copy .gdtf / MA3 .xml / .pxml fixture types into this library")
            }
        }
    }
}

struct FormatBadge: View {
    let format: FixtureFormat
    var body: some View {
        let tint: Color = switch format { case .gdtf: .blue; case .ma3: .orange; case .ma2: .gray }
        Text(format == .gdtf ? "GDTF" : format == .ma3 ? "MA3" : "MA2")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

struct FixtureDetail: View {
    @Environment(Store.self) private var store
    let f: FixtureType

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(f.name).font(.title3.bold())
                    Text(f.manufacturer).foregroundStyle(.secondary)
                    HStack { FormatBadge(format: f.format); if !f.revision.isEmpty { Text(f.revision).font(.caption).foregroundStyle(.secondary) } }
                }
                .padding(.vertical, 4)
            }
            Section("DMX Modes") {
                if f.modes.isEmpty {
                    Text(f.format == .ma2 ? "MA2 .pxml files are compressed; modes aren't shown." : "No modes found")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(f.modes.enumerated()), id: \.offset) { i, m in
                    HStack {
                        Text("\(i + 1)").foregroundStyle(.tertiary).monospacedDigit().frame(width: 18, alignment: .trailing)
                        Text(m.name).lineLimit(2)
                        Spacer()
                        Text("\(m.channels) ch").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Section("File") {
                LabeledContent("Name") { Text(f.fileName).textSelection(.enabled).lineLimit(3) }
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                LabeledContent("Modified") { Text(f.modified, format: .dateTime) }
                Button("Show in Finder") { store.reveal([f.url]) }
            }
        }
    }
}

// MARK: - Datapools

struct DatapoolsView: View {
    @Environment(Store.self) private var store
    @AppStorage("datapool") private var poolName = "presets"
    @AppStorage("showBackups") private var showBackups = false
    @State private var query = ""
    @State private var selection = Set<DatapoolItem.ID>()
    @State private var sortOrder = [KeyPathComparator(\DatapoolItem.name)]
    @State private var dropTarget = false

    var pool: Datapool? { store.pools.first { $0.name == poolName } ?? store.pools.first }
    var rows: [DatapoolItem] {
        (pool?.items ?? []).filter { i in
            (showBackups || !i.isBackup) &&
                (query.isEmpty || i.name.localizedCaseInsensitiveContains(query) || i.fileName.localizedCaseInsensitiveContains(query))
        }
        .sorted(using: sortOrder)
    }
    var selectedItems: [DatapoolItem] { (pool?.items ?? []).filter { selection.contains($0.id) } }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { pool?.name }, set: { if let n = $0 { poolName = n; selection = [] } })) {
                ForEach(store.pools) { p in
                    let n = p.items.filter { showBackups || !$0.isBackup }.count
                    Label {
                        HStack { Text(p.title); Spacer(); if n > 0 { Text("\(n)").foregroundStyle(.secondary) } }
                    } icon: { Image(systemName: p.icon) }
                    .foregroundStyle(n == 0 ? .secondary : .primary)
                    .tag(Optional(p.name))
                }
            }
            .listStyle(.inset)
            .frame(width: 210)
            Divider()
            itemsTable
        }
        .searchable(text: $query, prompt: "Filter \(pool?.title.lowercased() ?? "items")")
        .navigationTitle("Datapools")
        .navigationSubtitle(pool?.url.path ?? store.library?.datapoolsDir.path ?? "")
        .inspector(isPresented: Binding(get: { selectedItems.count == 1 }, set: { if !$0 { selection = [] } })) {
            if let item = selectedItems.first, selectedItems.count == 1 {
                DatapoolItemDetail(item: item).inspectorColumnWidth(min: 280, ideal: 340)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                let backups = pool?.items.filter(\.isBackup).count ?? 0
                if backups > 0 {
                    Toggle(isOn: $showBackups) { Label("Backups (\(backups))", systemImage: "clock.arrow.circlepath") }
                        .help("Show .bak copies")
                }
                LibraryPicker()
                Button {
                    if let pool { NSWorkspace.shared.open(pool.url) }
                } label: { Label("Pool Folder", systemImage: "folder") }
                Button {
                    guard let pool else { return }
                    let urls = LibraryFiles.chooseFiles(extensions: ["xml", "lua"], prompt: "Import")
                    if !urls.isEmpty { store.importDropped(urls, extensions: nil, into: pool.url) }
                } label: { Label("Import", systemImage: "square.and.arrow.down") }
                .help("Copy exported pool objects (.xml, plugin .lua) into this pool")
            }
        }
    }

    var itemsTable: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { i in
                HStack(spacing: 6) {
                    if i.isFolder { Image(systemName: "folder").foregroundStyle(.secondary) }
                    Text(i.name).fontWeight(.medium).foregroundStyle(i.isBackup ? .secondary : .primary)
                }
            }
            .width(min: 160, ideal: 240)
            TableColumn("Type", value: \.kind) { i in Text(i.kind).foregroundStyle(.secondary) }.width(min: 60, ideal: 80)
            TableColumn("Info", value: \.detail) { i in Text(i.detail).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 80, ideal: 120)
            TableColumn("Data Version", value: \.dataVersion) { i in Text(i.dataVersion).foregroundStyle(.secondary).monospacedDigit() }
                .width(min: 70, ideal: 90)
            TableColumn("Modified", value: \.modified) { i in
                Text(i.modified, format: .dateTime.day().month(.abbreviated).year()).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 100)
            TableColumn("Size", value: \.size) { i in
                Text(ByteCountFormatter.string(fromByteCount: i.size, countStyle: .file))
                    .foregroundStyle(.secondary).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(70)
        }
        .contextMenu(forSelectionType: DatapoolItem.ID.self) { ids in
            let urls = (pool?.items ?? []).filter { ids.contains($0.id) }.map(\.url)
            if urls.count == 1 {
                Button("Open") { NSWorkspace.shared.open(urls[0]) }
                Button("Duplicate") { store.duplicateLibraryFile(urls[0]) }
            }
            Button("Show in Finder") { store.reveal(urls) }
            if let pool { CopyToLibraryMenu(urls: urls, subfolder: "datapools/\(pool.name)") }
            Divider()
            Button("Move to Trash", role: .destructive) { selection.subtract(ids); store.trash(urls) }
        } primaryAction: { ids in
            (pool?.items ?? []).filter { ids.contains($0.id) }.forEach { NSWorkspace.shared.open($0.url) }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView((pool?.items.isEmpty ?? true) ? "Nothing in \(pool?.title ?? "this pool")" : "No matches",
                                       systemImage: pool?.icon ?? "tray",
                                       description: Text((pool?.items.isEmpty ?? true) ? "Export objects from onPC into the library, or drop files here." : ""))
            }
        }
        .background(dropTarget ? Color.accentColor.opacity(0.08) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let pool else { return false }
            store.importDropped(urls, extensions: nil, into: pool.url)
            return true
        } isTargeted: { dropTarget = $0 }
    }
}

struct DatapoolItemDetail: View {
    @Environment(Store.self) private var store
    let item: DatapoolItem
    @State private var preview = ""

    var shownAttributes: [(String, String)] {
        let skip: Set = ["Name", "Guid"]
        return item.attributes.filter { !skip.contains($0.key) && !$0.value.isEmpty }.sorted { $0.key < $1.key }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.title3.bold())
                    Text([item.kind, item.detail].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
                    if item.isBackup { Text("Backup copy").font(.caption).foregroundStyle(.orange) }
                }
                .padding(.vertical, 4)
            }
            if !item.components.isEmpty {
                Section("Lua Components") {
                    ForEach(item.components, id: \.self) { c in
                        let url = item.url.deletingLastPathComponent().appendingPathComponent(c)
                        let exists = FileManager.default.fileExists(atPath: url.path)
                        HStack {
                            Image(systemName: exists ? "doc.text" : "exclamationmark.triangle").foregroundStyle(exists ? Color.secondary : Color.orange)
                            Text(c)
                            Spacer()
                            if exists { Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.link) } else { Text("missing").foregroundStyle(.orange) }
                        }
                    }
                }
            }
            if !shownAttributes.isEmpty {
                Section("Properties") {
                    ForEach(shownAttributes, id: \.0) { k, v in
                        LabeledContent(k) { Text(v).textSelection(.enabled).lineLimit(2) }
                    }
                }
            }
            if !preview.isEmpty {
                Section("Preview") {
                    Text(preview).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section("File") {
                LabeledContent("Name") { Text(item.fileName).textSelection(.enabled) }
                if !item.dataVersion.isEmpty { LabeledContent("Data version", value: item.dataVersion) }
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                LabeledContent("Modified") { Text(item.modified, format: .dateTime) }
                HStack {
                    Button("Open") { NSWorkspace.shared.open(item.url) }
                    Button("Show in Finder") { store.reveal([item.url]) }
                }
            }
        }
        .task(id: item.url) { preview = Self.loadPreview(item) }
    }

    /// First lines of Lua sources (including backups) so they can be told apart at a glance.
    static func loadPreview(_ item: DatapoolItem) -> String {
        guard !item.isFolder, item.fileName.contains(".lua"),
              let h = try? FileHandle(forReadingFrom: item.url) else { return "" }
        defer { try? h.close() }
        let text = String(decoding: (try? h.read(upToCount: 4000)) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).prefix(30).joined(separator: "\n")
    }
}

// MARK: - Installing versions

struct InstallView: View {
    @Environment(Store.self) private var store
    @State private var dropTarget = false

    static let downloadsPage = URL(string: "https://www.malighting.com/downloads/products/grandma3/")!

    func installed(_ p: InstallerPackage) -> Bool { store.allBuilds.contains { $0.fullVersion == p.version } }

    var body: some View {
        List {
            Section {
                if store.installers.isEmpty {
                    ContentUnavailableView("No installers found", systemImage: "arrow.down.app",
                                           description: Text("Download a grandMA3 onPC macOS release from MA Lighting, then drop the .zip or .pkg here."))
                }
                ForEach(store.installers) { p in InstallerRow(pkg: p, installed: installed(p)) }
            } header: {
                Text("Installers in Downloads and installation_packages")
            }
            Section("Installed builds") {
                ForEach(store.allBuilds) { b in
                    HStack {
                        Image(systemName: "app.badge.checkmark").foregroundStyle(.secondary)
                        Text(b.fullVersion).monospacedDigit().fontWeight(.medium)
                        Text(b.name).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if store.versions.contains(where: { $0.running?.build == b }) {
                            StatusDot(on: true); Text("Running").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Launch") { store.launch(b) }
                        Button {
                            switch b.kind {
                            case .app(let u), .crossover(let u): store.reveal([u])
                            case .launcherSlot(let l, _): store.reveal([l])
                            }
                        } label: { Image(systemName: "magnifyingglass") }
                        .help("Show in Finder")
                    }
                }
            }
        }
        .background(dropTarget ? Color.accentColor.opacity(0.08) : .clear)
        .dropDestination(for: URL.self) { urls, _ in store.addInstallers(urls); return true } isTargeted: { dropTarget = $0 }
        .navigationTitle("Install Versions")
        .navigationSubtitle("Older versions install into grandMA3.app; 2.5+ install as their own apps")
        .toolbar {
            ToolbarItemGroup {
                Button { NSWorkspace.shared.open(Self.downloadsPage) } label: {
                    Label("MA Downloads", systemImage: "safari")
                }
                .help("Open MA Lighting's grandMA3 downloads page")
                Button {
                    let urls = LibraryFiles.chooseFiles(extensions: ["zip", "pkg"], prompt: "Add")
                    if !urls.isEmpty { store.addInstallers(urls) }
                } label: { Label("Add Installer", systemImage: "plus") }
                .help("Copy an installer into ~/MALightingTechnology/installation_packages")
            }
        }
    }
}

struct InstallerRow: View {
    @Environment(Store.self) private var store
    let pkg: InstallerPackage
    let installed: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: pkg.url.pathExtension.lowercased() == "zip" ? "doc.zipper" : "shippingbox")
                .font(.title2).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("grandMA3 onPC \(pkg.version)").fontWeight(.semibold)
                    if installed {
                        Text("Installed").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(.green.opacity(0.15), in: Capsule())
                    }
                }
                Text("\(pkg.url.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: pkg.size, countStyle: .file)) · \(pkg.url.deletingLastPathComponent().lastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let status = store.installing[pkg.url] {
                ProgressView().controlSize(.small)
                Text(status).font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Show in Finder") { store.reveal([pkg.url]) }
                Button("Open in Installer") { store.openInInstaller(pkg) }
                    .help("Unzip and open the .pkg in Apple's Installer app")
                Button(installed ? "Reinstall" : "Install") { confirmInstall() }
                    .buttonStyle(.borderedProminent)
                    .tint(installed ? .gray : .accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    func confirmInstall() {
        let alert = NSAlert()
        alert.messageText = "\(installed ? "Reinstall" : "Install") grandMA3 onPC \(pkg.version)?"
        alert.informativeText = "macOS will ask for your administrator password. Quit any running onPC first."
            + (pkg.url.pathExtension.lowercased() == "zip" ? " The zip is unpacked to a temporary folder first." : "")
        alert.addButton(withTitle: installed ? "Reinstall" : "Install")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.install(pkg) }
    }
}
