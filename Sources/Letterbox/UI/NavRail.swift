import SwiftUI

struct NavRail: View {
    @Environment(MailStore.self) private var store
    @State private var addingAlias = false
    @State private var aliasAccount = ""
    @State private var newAlias = ""
    @State private var customizing = false
    @AppStorage("sidebarMoreExpanded") private var moreExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 38) // traffic lights
            brand
                .padding(.horizontal, Theme.s(6))
                .padding(.bottom, Theme.s(16))
            HStack(spacing: Theme.s(8)) {
                PillButton(title: "New message", symbol: "square.and.pencil", style: .primary, expand: true) { store.newMessage() }
                IconButton(symbol: "command", help: "Search or ask Claude (⌘K)", size: 30) { store.showPalette = true }
                    .panel(radius: 9, fill: Theme.raised)
            }
            .padding(.bottom, Theme.s(18))

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.s(2)) {
                    let groups = store.sidebarGroups
                    let shown = groups.filter { store.isShown($0) }
                    let hidden = groups.filter { !store.isShown($0) }
                    NavItem(title: "Dashboard", symbol: "square.grid.2x2", item: .dashboard, badge: store.dashboard.needsReply.count)
                        .padding(.leading, gutter)
                    sectionLabel("Mailboxes")
                    ForEach(shown.filter { !$0.isCustom }) { groupRows($0) }
                    let shownFolders = shown.filter(\.isCustom)
                    if !shownFolders.isEmpty {
                        sectionLabel("Folders")
                        ForEach(shownFolders) { groupRows($0) }
                    }
                    moreSection(hidden)
                    addressesSection
                }
                .padding(.bottom, Theme.s(12))
            }

            ClaudeStatusCard()
                .padding(.bottom, Theme.s(10))
            AccountRow()
                .padding(.bottom, Theme.s(12))
        }
        .padding(.horizontal, Theme.s(12))
        .background {
            if Theme.isGlass { GlassSidebarBackground().ignoresSafeArea() } else { Theme.rail }
        }
    }

    /// Room for the open/close arrows, only needed when groups can open into accounts.
    private var gutter: CGFloat { store.multipleAccounts ? 16 : 0 }

    private var brand: some View {
        HStack(spacing: Theme.s(10)) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.ink)
                Image(systemName: "envelope").font(Theme.font(size: 11, weight: .semibold)).foregroundStyle(Theme.onInk)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text("Letterbox").font(Theme.serif(16, .semibold)).foregroundStyle(Theme.text)
                Text("with Claude").font(Theme.font(size: 10.5, weight: .medium)).foregroundStyle(Theme.text3)
            }
            Spacer()
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).microLabel().padding(.leading, Theme.s(10)).padding(.top, Theme.s(16)).padding(.bottom, Theme.s(5))
    }

    // MARK: Groups

    /// A mailbox or folder name across accounts; opens into one row per account.
    @ViewBuilder private func groupRows(_ g: SidebarGroup) -> some View {
        let expandable = store.canExpand(g)
        let expanded = expandable && store.sidebarExpanded.contains(g.key)
        HStack(spacing: 0) {
            if store.multipleAccounts {
                Button { withAnimation(.snappy(duration: 0.2)) { store.toggleExpanded(g) } } label: {
                    Image(systemName: "chevron.right")
                        .font(Theme.font(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.text3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: gutter, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(expandable ? 1 : 0)
                .disabled(!expandable)
                .help(expanded ? "Hide accounts" : "Show each account")
            }
            NavItem(title: g.title, symbol: g.symbol, item: g.item, badge: g.badge, quietBadge: g.quietBadge)
                .dropDestination(for: String.self) { ids, _ in drop(ids, on: g) }
                .help(store.multipleAccounts && g.isCustom && g.folders.count == 1 ? store.accountName(g.folders[0].account) : "")
                .contextMenu {
                    if store.isShown(g) {
                        Button("Hide from Sidebar") { withAnimation(.snappy(duration: 0.2)) { store.setShown(g, false) } }
                    } else {
                        Button("Show in Sidebar") { withAnimation(.snappy(duration: 0.2)) { store.setShown(g, true) } }
                    }
                    Button("Customize Sidebar…") { customizing = true }
                }
        }
        if expanded {
            ForEach(g.folders) { f in
                NavItem(title: store.accountName(f.account), symbol: g.symbol, item: .folder(f.id), badge: store.badge(for: f),
                        quietBadge: f.role != .inbox, mark: AccountMark(name: store.session(f.account)?.account.displayName ?? "",
                                                                         email: store.session(f.account)?.account.email ?? "",
                                                                         color: store.accountColor(f.account)))
                    .padding(.leading, gutter + 12)
                    .help(store.session(f.account)?.account.email ?? "")
                    .dropDestination(for: String.self) { ids, _ in
                        store.move(ids, to: f)
                        return true
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func drop(_ ids: [String], on g: SidebarGroup) -> Bool {
        switch g.kind {
        case .role(let role): store.move(ids, toRole: role)
        case .flagged: store.toggleFlag(ids)
        case .custom(let name): store.move(ids, toFolderNamed: name)
        }
        return true
    }

    /// Everything the user hasn't pinned to the sidebar, plus the way to choose.
    @ViewBuilder private func moreSection(_ hidden: [SidebarGroup]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter)
            Button { withAnimation(.snappy(duration: 0.2)) { moreExpanded.toggle() } } label: {
                HStack(spacing: Theme.s(10)) {
                    Image(systemName: "ellipsis.circle").font(Theme.font(size: 13, weight: .medium)).foregroundStyle(Theme.text2).frame(width: 18)
                    Text(moreExpanded ? "Less" : "More").font(Theme.font(size: 13, weight: .medium)).foregroundStyle(Theme.text2)
                    Spacer(minLength: 4)
                    if !moreExpanded && !hidden.isEmpty {
                        Text("\(hidden.count)").font(Theme.font(size: 10.5, weight: .bold).monospacedDigit()).foregroundStyle(Theme.text3)
                            .padding(.horizontal, Theme.s(2))
                    }
                    Image(systemName: "chevron.down").font(Theme.font(size: 8.5, weight: .bold)).foregroundStyle(Theme.text3)
                        .rotationEffect(.degrees(moreExpanded ? 180 : 0))
                }
                .padding(.horizontal, Theme.s(10))
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Folders you haven’t added to the sidebar")
        }
        .padding(.top, Theme.s(6))
        .popover(isPresented: $customizing, arrowEdge: .trailing) { SidebarCustomizer() }
        if moreExpanded {
            ForEach(hidden) { groupRows($0) }
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter)
                Button { customizing = true } label: {
                    Text("Customize Sidebar…")
                        .font(Theme.font(size: 12, weight: .medium)).foregroundStyle(Theme.text3)
                        .padding(.horizontal, Theme.s(10)).frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Addresses

    @ViewBuilder private var addressesSection: some View {
        HStack {
            sectionLabel("Addresses")
            Spacer()
            Button {
                aliasAccount = store.account?.id ?? ""
                addingAlias = true
            } label: {
                Image(systemName: "plus").font(Theme.font(size: 10, weight: .bold)).foregroundStyle(Theme.text3)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.s(14))
            .help("Add an alias")
            .popover(isPresented: $addingAlias, arrowEdge: .trailing) { aliasPopover }
        }
        ForEach(store.addresses) { alias in
            NavItem(title: alias.email, symbol: alias.isPrimary ? "person.crop.circle" : "at", item: .address(alias.email), badge: alias.unread, quietBadge: true, mono: true)
                .contextMenu {
                    Button("New Message from This Address") { store.newMessage(from: alias.email) }
                    Button("Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(alias.email, forType: .string)
                    }
                    if !alias.isPrimary {
                        Divider()
                        Button("Hide Alias") { store.setAlias(alias.email, hidden: true) }
                    }
                }
        }
    }

    private var aliasPopover: some View {
        VStack(alignment: .leading, spacing: Theme.s(10)) {
            Text("Add an alias").font(.headline)
            Text("Letterbox detects aliases from your mail automatically. Add one here if it hasn’t received anything yet.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.multipleAccounts {
                Picker("Account", selection: $aliasAccount) {
                    ForEach(store.accounts) { Text($0.email).tag($0.id) }
                }
            }
            TextField("alias@example.com", text: $newAlias).textFieldStyle(.roundedBorder).onSubmit(commitAlias)
            HStack {
                Spacer()
                Button("Cancel") { addingAlias = false }
                Button("Add", action: commitAlias).keyboardShortcut(.defaultAction).disabled(!newAlias.contains("@"))
            }
        }
        .padding(Theme.s(16))
        .frame(width: 300)
    }

    private func commitAlias() {
        guard newAlias.contains("@") else { return }
        store.addAlias(newAlias, to: aliasAccount)
        newAlias = ""
        addingAlias = false
    }
}

/// Checkboxes for every mailbox and folder: checked ones sit in the sidebar, the rest under More.
private struct SidebarCustomizer: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        let groups = store.sidebarGroups
        VStack(alignment: .leading, spacing: 0) {
            Text("Show in Sidebar").font(.headline).padding(.bottom, Theme.s(4))
            Text("Unchecked items stay under More.").font(.caption).foregroundStyle(.secondary).padding(.bottom, Theme.s(10))
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s(6)) {
                    Text("Mailboxes").microLabel().padding(.top, Theme.s(2))
                    ForEach(groups.filter { !$0.isCustom }) { row($0) }
                    let custom = groups.filter(\.isCustom)
                    if !custom.isEmpty {
                        Text("Folders").microLabel().padding(.top, Theme.s(10))
                        ForEach(custom) { row($0) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 420)
        }
        .padding(Theme.s(16))
        .frame(width: 300)
    }

    private func row(_ g: SidebarGroup) -> some View {
        Toggle(isOn: Binding(get: { store.isShown(g) }, set: { v in withAnimation(.snappy(duration: 0.2)) { store.setShown(g, v) } })) {
            HStack(spacing: Theme.s(8)) {
                Image(systemName: g.symbol).foregroundStyle(.secondary).frame(width: 16)
                Text(g.title).lineLimit(1)
                if store.multipleAccounts && g.isCustom {
                    Text(g.folders.map { store.accountName($0.account) }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

private struct NavItem: View {
    @Environment(MailStore.self) private var store
    let title: String
    let symbol: String
    let item: SidebarItem
    var badge = 0
    var quietBadge = false
    var ai = false
    var mono = false
    /// Shown instead of the symbol, for a per-account row.
    var mark: AccountMark?
    @State private var hovering = false

    private var selected: Bool { store.sidebarSelection == item && store.searchText.isEmpty }

    var body: some View {
        Button {
            store.searchText = ""
            store.sidebarSelection = item
        } label: {
            HStack(spacing: Theme.s(10)) {
                Group {
                    if let mark {
                        mark
                    } else if ai {
                        Image(systemName: symbol).foregroundStyle(Theme.aurora)
                    } else {
                        Image(systemName: selected && symbol != "at" ? symbol + ".fill" : symbol)
                            .foregroundStyle(selected ? Theme.accentText : Theme.text2)
                    }
                }
                .font(Theme.font(size: 13, weight: .medium))
                .frame(width: 18)
                Text(title)
                    .font(Theme.font(size: mono ? 12.5 : 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.text : Theme.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)")
                        .font(Theme.font(size: 10.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(quietBadge ? Theme.text3 : Theme.text)
                        .padding(.horizontal, quietBadge ? 2 : 7)
                        .frame(minWidth: 20, minHeight: 18)
                        .background {
                            if !quietBadge {
                                Capsule().fill(Theme.accentSoft)
                            }
                        }
                }
            }
            .padding(.horizontal, Theme.s(10))
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? Theme.accentSoft : (hovering ? Theme.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ClaudeStatusCard: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s(7)) {
            HStack(spacing: Theme.s(7)) {
                SparkleIcon(size: 11)
                Text("Claude").font(Theme.font(size: 12, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                Circle().fill(dotColor).frame(width: 6, height: 6)
            }
            Text(statusText)
                .font(Theme.font(size: 11))
                .foregroundStyle(Theme.text2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if store.aiStatus.isWorking { ThinkingBar() }
        }
        .padding(Theme.s(11))
        .aurora(radius: 11, animated: store.aiStatus.isWorking)
        .onTapGesture {
            if store.aiStatus == .missing || store.aiStatus == .off {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    private var dotColor: Color {
        switch store.aiStatus {
        case .ready: return Theme.success
        case .working: return Theme.high
        case .failed, .missing: return Theme.urgent
        default: return Theme.text3
        }
    }

    private var statusText: String {
        switch store.aiStatus {
        case .unknown: return "Connecting…"
        case .off: return "Turned off in Settings"
        case .missing: return "Claude CLI not found. Click to set it up."
        case .ready: return "Ready · \(store.aiModel.capitalized) · \(store.insights.count) analyzed"
        case .working(let s): return s
        case .failed(let s): return s
        }
    }
}

private struct AccountRow: View {
    @Environment(MailStore.self) private var store

    private var title: String {
        store.multipleAccounts ? "\(store.accounts.count) accounts" : (store.account?.label ?? "")
    }

    var body: some View {
        HStack(spacing: Theme.s(10)) {
            AvatarView(name: store.account?.displayName ?? "", email: store.account?.email ?? "", size: 30)
            VStack(alignment: .leading, spacing: Theme.s(1)) {
                Text(title)
                    .font(Theme.font(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    .help(store.accounts.map(\.email).joined(separator: "\n"))
                syncLine
            }
            Spacer(minLength: 0)
            Button { store.addingAccount = true } label: {
                Image(systemName: "person.crop.circle.badge.plus").font(Theme.font(size: 13)).foregroundStyle(Theme.text3).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Add an account")
            SettingsLink {
                Image(systemName: "gearshape").font(Theme.font(size: 13)).foregroundStyle(Theme.text3).frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, Theme.s(4))
    }

    @ViewBuilder private var syncLine: some View {
        Group {
            if store.isSyncing {
                Text(store.syncProgress ?? "Syncing…")
            } else if let error = store.syncError {
                Text(error).foregroundStyle(Theme.urgent).help(error)
            } else if let last = store.lastSync {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(Date().timeIntervalSince(last) < 60 ? "Synced just now" : "Synced \(last.formatted(.relative(presentation: .named)))")
                }
            } else {
                Text("Connecting…")
            }
        }
        .font(Theme.font(size: 10.5))
        .foregroundStyle(Theme.text3)
        .lineLimit(1)
    }
}

