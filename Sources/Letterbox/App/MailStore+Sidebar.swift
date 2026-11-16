import SwiftUI

/// One row in the sidebar: a kind of mailbox or a custom folder name, gathered across accounts.
struct SidebarGroup: Identifiable {
    enum Kind: Hashable {
        case role(FolderRole)
        case flagged
        case custom(String)
    }

    let kind: Kind
    let title: String
    let symbol: String
    /// What opens when the row is clicked.
    let item: SidebarItem
    /// The matching folder in each account, in account order.
    let folders: [Folder]
    let badge: Int
    let quietBadge: Bool

    var id: String { key }
    var key: String {
        switch kind {
        case .role(let r): return "role:\(r.rawValue)"
        case .flagged: return "flagged"
        case .custom(let name): return "folder:\(name)"
        }
    }

    var isCustom: Bool { if case .custom = kind { return true }; return false }
    /// Standard mailboxes start visible; custom folders start under More.
    var visibleByDefault: Bool { !isCustom }
}

extension MailStore {
    /// Custom folders with this lowercased display name, one per account at most.
    func folders(named name: String) -> [Folder] {
        folders.filter { $0.role == .custom && $0.displayName.lowercased() == name }
    }

    /// Every possible sidebar row, in display order.
    var sidebarGroups: [SidebarGroup] {
        var out: [SidebarGroup] = []
        for role in mailboxRoles {
            out.append(SidebarGroup(kind: .role(role), title: mailboxTitle(role), symbol: role.symbol, item: .mailbox(role),
                                    folders: folders.filter { $0.role == role }, badge: mailboxBadge(role), quietBadge: role != .inbox))
            if role == .inbox {
                out.append(SidebarGroup(kind: .flagged, title: "Flagged", symbol: "flag", item: .flagged, folders: [],
                                        badge: flaggedCount, quietBadge: true))
            }
        }
        var byName: [String: [Folder]] = [:]
        for f in folders where f.role == .custom { byName[f.displayName.lowercased(), default: []].append(f) }
        for (name, list) in byName.sorted(by: { $0.key < $1.key }) {
            out.append(SidebarGroup(kind: .custom(name), title: list[0].displayName, symbol: FolderRole.custom.symbol,
                                    item: list.count == 1 ? .folder(list[0].id) : .folderGroup(name),
                                    folders: list, badge: list.reduce(0) { $0 + $1.unread }, quietBadge: true))
        }
        return out
    }

    func isShown(_ g: SidebarGroup) -> Bool { sidebarVisibility[g.key] ?? g.visibleByDefault }

    func setShown(_ g: SidebarGroup, _ shown: Bool) {
        sidebarVisibility[g.key] = shown == g.visibleByDefault ? nil : shown
    }

    /// Whether a group opens into one row per account.
    func canExpand(_ g: SidebarGroup) -> Bool {
        guard multipleAccounts else { return false }
        switch g.kind {
        case .role: return !g.folders.isEmpty
        case .flagged: return false
        case .custom: return g.folders.count > 1
        }
    }

    func toggleExpanded(_ g: SidebarGroup) {
        if sidebarExpanded.contains(g.key) { sidebarExpanded.remove(g.key) } else { sidebarExpanded.insert(g.key) }
    }

    /// Label for one account's row inside a group. Adds the folder name when that account has more than one.
    func rowTitle(_ f: Folder, in g: SidebarGroup) -> String {
        let shared = g.folders.filter { $0.account == f.account }.count > 1
        return shared ? "\(accountName(f.account)) · \(f.displayName)" : accountName(f.account)
    }

    /// Badge for one account's row inside a group.
    func badge(for f: Folder) -> Int {
        switch f.role {
        case .drafts: return f.total
        case .sent, .junk, .trash: return 0
        default: return f.unread
        }
    }

    // MARK: Account names and colors

    /// Short account name for the sidebar: the user's nickname, else the provider, else the domain.
    func accountName(_ id: String) -> String {
        guard let a = sessions[id]?.account else { return "" }
        if !a.nickname.isEmpty { return a.nickname }
        let guess = Self.defaultNickname(a)
        let clash = accounts.contains { $0.id != id && $0.nickname.isEmpty && Self.defaultNickname($0) == guess }
        return clash ? a.email : guess
    }

    static func defaultNickname(_ a: Account) -> String {
        if a.provider != "custom" { return MailProvider.byID(a.provider).name }
        return a.email.split(separator: "@").last.map(String.init) ?? a.email
    }

    func accountColor(_ id: String) -> Color {
        Theme.accountColor(accounts.firstIndex { $0.id == id } ?? 0)
    }
}
