import AppKit
import SwiftUI

struct SyncSidebarRow: View {
    @Environment(Store.self) private var store
    var body: some View {
        Label {
            HStack {
                Text("Cloud Sync")
                Spacer()
                if store.syncing { ProgressView().controlSize(.mini) }
                else if store.syncError != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                else if store.lastSync != nil { Image(systemName: "checkmark.icloud").foregroundStyle(.secondary) }
            }
        } icon: { Image(systemName: "icloud") }
    }
}

struct SyncView: View {
    @Environment(Store.self) private var store
    @State private var token = Keychain.token() ?? ""
    @State private var testResult: (ok: Bool, text: String)?
    @State private var testing = false

    static let serverFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("sync-server")

    var configured: Bool { !store.syncSettings.serverURL.isEmpty && !token.isEmpty }

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: store.syncError != nil ? "exclamationmark.icloud" : "icloud")
                        .font(.system(size: 28)).foregroundStyle(store.syncError != nil ? .orange : .accentColor)
                        .frame(width: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        if store.syncing { Text("Syncing…").font(.headline) }
                        else if let e = store.syncError { Text("Sync failed").font(.headline); Text(e).font(.caption).foregroundStyle(.secondary) }
                        else if let last = store.lastSync {
                            Text("Last synced \(last.formatted(.relative(presentation: .named)))").font(.headline)
                            if let s = store.lastSyncSummary { Text(s).font(.caption).foregroundStyle(.secondary) }
                        } else { Text(configured ? "Not synced yet" : "Set up your sync server below").font(.headline) }
                    }
                    Spacer()
                    Button { store.syncNow() } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.syncing || !configured)
                }
                .padding(.vertical, 4)
            }

            Section("Server") {
                TextField("Server URL", text: $store.syncSettings.serverURL, prompt: Text("https://masync.example.com"))
                SecureField("Token", text: $token, prompt: Text("SYNC_TOKEN from the server's .env"))
                    .onChange(of: token) { _, t in Keychain.setToken(t) }
                TextField("This Mac's name", text: $store.syncSettings.deviceName)
                    .help("Shown on the server and in conflict copies")
                HStack {
                    Button(testing ? "Testing…" : "Test Connection") {
                        testing = true
                        Task {
                            let err = await store.testConnection(server: store.syncSettings.serverURL, token: token)
                            testResult = err == nil ? (true, "Connected") : (false, err!)
                            testing = false
                        }
                    }
                    .disabled(testing || !configured)
                    if let r = testResult {
                        Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(r.ok ? .green : .red).font(.callout)
                    }
                    Spacer()
                    Button("Server Setup Files") { NSWorkspace.shared.open(Self.serverFolder) }
                        .help("Docker + Cloudflare Tunnel setup for the sync server")
                }
            }

            Section("What to sync") {
                Toggle("grandMA3 showfiles (every version)", isOn: $store.syncSettings.ma3Shows)
                Toggle("grandMA3 library: color themes, fixture types, datapools", isOn: $store.syncSettings.ma3Library)
                Toggle("grandMA2 showfiles (CrossOver)", isOn: $store.syncSettings.ma2Shows)
                Picker("Sync automatically", selection: $store.syncSettings.autoSyncMinutes) {
                    Text("Off").tag(0)
                    Text("Every 5 minutes").tag(5)
                    Text("Every 15 minutes").tag(15)
                    Text("Every 30 minutes").tag(30)
                    Text("Every hour").tag(60)
                }
                Text("Shows are only synced for versions installed on this Mac. Files saved in the last 15 seconds wait for the next sync. When a file changed on two machines, both copies are kept and the other one is renamed “(conflict …)”. Deleted or overwritten files stay in the server's history.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Activity") {
                if store.syncLog.isEmpty {
                    Text("Nothing yet").foregroundStyle(.secondary)
                }
                ForEach(store.syncLog.prefix(100)) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(e.kind.rawValue).frame(width: 16)
                            .foregroundStyle(e.kind == .error ? .red : e.kind == .conflict ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.path).lineLimit(1).truncationMode(.middle)
                            Text(e.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(e.date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Cloud Sync")
        .navigationSubtitle(store.syncSettings.serverURL.isEmpty ? "Not configured" : store.syncSettings.serverURL)
    }
}
