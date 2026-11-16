import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ClaudeSettings()
                .tabItem { Label("Claude", systemImage: "sparkle") }
            AliasSettings()
                .tabItem { Label("Addresses", systemImage: "at") }
            ReadingSettings()
                .tabItem { Label("Reading & Writing", systemImage: "text.alignleft") }
        }
        .frame(width: 560, height: 540)
    }
}

private struct AccountSettings: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var removing: Account?

    var body: some View {
        Form {
            if store.accounts.isEmpty {
                Text("Not signed in.").foregroundStyle(.secondary)
            } else {
                ForEach(store.accounts) { account in
                    Section(account.email) {
                        TextField("Display name", text: Binding(
                            get: { store.accounts.first { $0.id == account.id }?.displayName ?? "" },
                            set: { store.updateDisplayName($0, for: account.id) }
                        ))
                        TextField("Name in sidebar", text: Binding(
                            get: { store.accounts.first { $0.id == account.id }?.nickname ?? "" },
                            set: { store.updateNickname($0, for: account.id) }
                        ), prompt: Text(MailStore.defaultNickname(account)))
                        LabeledContent("Incoming", value: "\(account.imapHost):\(account.imapPort) · \(account.imapSecurity.rawValue)")
                        LabeledContent("Outgoing", value: "\(account.smtpHost):\(account.smtpPort) · \(account.smtpSecurity.rawValue)")
                        HStack {
                            Spacer()
                            Button("Remove Account…", role: .destructive) { removing = account }
                        }
                    }
                }
                Section {
                    Button("Add Account…") {
                        openWindow(id: "main")
                        store.addingAccount = true
                    }
                } footer: {
                    Text("Mail from all accounts is shown together. Each account keeps its own folders and addresses, and replies go out from the account that received the message.")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove \(removing?.email ?? "this account") from Letterbox?", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), presenting: removing) { a in
            Button("Remove Account", role: .destructive) { store.removeAccount(a.id) }
        } message: { _ in
            Text("Its password and downloaded mail will be removed from this Mac. Nothing on the server is changed.")
        }
    }
}

private struct AliasSettings: View {
    @Environment(MailStore.self) private var store
    @State private var newAlias: [String: String] = [:]

    var body: some View {
        Form {
            ForEach(store.accounts) { account in
                Section {
                    ForEach(store.addresses(in: account.id)) { a in
                        HStack {
                            Image(systemName: a.isPrimary ? "person.crop.circle" : "at").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.email)
                                Text(a.isPrimary ? "Primary" : (a.isManual ? "Added by you" : "Detected from your mail"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !a.isPrimary {
                                Button("Hide") { store.setAlias(a.email, hidden: true) }
                            }
                        }
                    }
                    let hidden = store.hiddenAliases.filter { $0.account == account.id }
                    ForEach(hidden) { a in
                        HStack {
                            Text(a.email).foregroundStyle(.secondary)
                            Spacer()
                            Button("Show") { store.setAlias(a.email, hidden: false) }
                        }
                    }
                    HStack {
                        TextField("Add an alias: alias@example.com", text: binding(for: account.id))
                            .onSubmit { add(account.id) }
                        Button("Add") { add(account.id) }.disabled(!(newAlias[account.id] ?? "").contains("@"))
                    }
                } header: {
                    Text(store.multipleAccounts ? account.email : "Your addresses")
                }
            }
            Section {} footer: {
                Text("Replies are sent from the address a message was delivered to. Choose any of these in the From menu when writing.")
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(get: { newAlias[id] ?? "" }, set: { newAlias[id] = $0 })
    }

    private func add(_ id: String) {
        store.addAlias(newAlias[id] ?? "", to: id)
        newAlias[id] = ""
    }
}

private struct ReadingSettings: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Reading") {
                Toggle("Block remote images until I load them", isOn: $store.blockRemoteContent)
            }
            Section("Sending") {
                Toggle("Save a copy of sent messages to Sent", isOn: $store.saveToSent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Signature")
                    TextEditor(text: $store.signature)
                        .font(.system(size: 13))
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.background))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                }
            }
        }
        .formStyle(.grouped)
    }
}


private struct ClaudeSettings: View {
    @Environment(MailStore.self) private var store
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Use Claude to triage, summarize and draft", isOn: $store.aiEnabled)
                Picker("Model", selection: $store.aiModel) {
                    Text("Sonnet — balanced (recommended)").tag("sonnet")
                    Text("Opus — most capable").tag("opus")
                    Text("Haiku — fastest").tag("haiku")
                }
                .disabled(!store.aiEnabled)
            } footer: {
                Text("Letterbox runs your local Claude Code CLI with all tools disabled, so Claude can only read the text Letterbox sends it. Message content is processed under your Claude account.")
            }
            Section("Claude Code CLI") {
                HStack {
                    TextField("Path to claude", text: $store.claudePath)
                    Button("Detect") {
                        store.claudePath = ""
                        store.setupAI()
                    }
                }
                LabeledContent("Status") {
                    switch store.aiStatus {
                    case .ready: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .missing: Label("Not found", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    case .off: Text("Off").foregroundStyle(.secondary)
                    case .working(let s): Text(s).foregroundStyle(.secondary)
                    case .failed(let s): Text(s).foregroundStyle(.red).lineLimit(3)
                    case .unknown: Text("Checking…").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(testing ? "Testing…" : "Test Connection") { test() }.disabled(testing || !store.aiReady)
                    Button("Re-analyze Inbox") { store.scheduleTriage(force: true) }.disabled(!store.aiReady)
                    Spacer()
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func test() {
        guard let claude = store.claude else { return }
        testing = true
        testResult = nil
        Task {
            var text = ""
            do {
                for try await chunk in claude.stream(prompt: "Reply with exactly: Letterbox is connected.", system: "You are a connectivity check.") { text += chunk }
                testResult = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}

private struct AppearanceSettingsView: View {
    @State private var settings = AppearanceSettings.shared

    var body: some View {
        Form {
            Section("Colors") {
                Picker("Appearance", selection: $settings.mode) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(settings.palette.alwaysDark)
                .help(settings.palette.alwaysDark ? "\(settings.palette.title) is always dark." : "")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 10)], spacing: 10) {
                    ForEach(ThemePalette.allCases) { palette in
                        PaletteSwatch(palette: palette, selected: settings.palette == palette) {
                            settings.palette = palette
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Picker("Font", selection: $settings.font) {
                    ForEach(ThemeFont.allCases) { f in
                        Text(f.title).font(.system(size: 13, design: f.design)).tag(f)
                    }
                }
                Picker("Text size", selection: $settings.textSize) {
                    ForEach(ThemeTextSize.allCases) { Text($0.title).tag($0) }
                }
                Picker("Spacing", selection: $settings.density) {
                    ForEach(ThemeDensity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Text & Layout")
            } footer: {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { settings.reset() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A small preview card for one color theme.
private struct PaletteSwatch: View {
    let palette: ThemePalette
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let c = palette.colors
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    c.rail.frame(width: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Capsule().fill(c.text).frame(width: 34, height: 4)
                        Capsule().fill(c.text3).frame(width: 46, height: 3)
                        HStack(spacing: 4) {
                            Circle().fill(c.accent).frame(width: 7, height: 7)
                            Circle().fill(c.urgent).frame(width: 7, height: 7)
                            Circle().fill(c.success).frame(width: 7, height: 7)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(c.panel)
                }
                .frame(height: 46)
                .background(c.canvas)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1)
                )
                Text(palette.title).font(.system(size: 11.5, weight: selected ? .semibold : .regular))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(palette.subtitle)
    }
}
