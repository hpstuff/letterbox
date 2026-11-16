import Foundation

struct Account: Codable, Equatable, Identifiable {
    /// Stable local identifier. The first account from single-account builds keeps `legacyID`
    /// so its existing cache, password and briefing carry over unchanged.
    var id: String = UUID().uuidString
    var email: String
    var displayName: String
    /// Short name shown in the sidebar, e.g. "Work". Empty means Letterbox picks one.
    var nickname = ""
    var provider: String = "custom"
    var username: String = ""
    var imapHost = ""
    var imapPort: UInt16 = 993
    var imapSecurity: ConnectionSecurity = .tls
    var smtpHost = ""
    var smtpPort: UInt16 = 465
    var smtpSecurity: ConnectionSecurity = .tls
    /// Some providers (e.g. Gmail) file sent mail automatically.
    var serverSavesSent = false

    static let legacyID = "default"

    var loginName: String { username.isEmpty ? email : username }
    var address: MailAddress { MailAddress(name: displayName, email: email) }
    var label: String { displayName.isEmpty ? email : displayName }

    init(email: String, displayName: String) {
        self.email = email
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Self.legacyID
        email = try c.decode(String.self, forKey: .email)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "custom"
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        imapHost = try c.decodeIfPresent(String.self, forKey: .imapHost) ?? ""
        imapPort = try c.decodeIfPresent(UInt16.self, forKey: .imapPort) ?? 993
        imapSecurity = try c.decodeIfPresent(ConnectionSecurity.self, forKey: .imapSecurity) ?? .tls
        smtpHost = try c.decodeIfPresent(String.self, forKey: .smtpHost) ?? ""
        smtpPort = try c.decodeIfPresent(UInt16.self, forKey: .smtpPort) ?? 465
        smtpSecurity = try c.decodeIfPresent(ConnectionSecurity.self, forKey: .smtpSecurity) ?? .tls
        serverSavesSent = try c.decodeIfPresent(Bool.self, forKey: .serverSavesSent) ?? false
    }

    // MARK: Persistence

    /// All accounts, in the order they were added. Upgrades a single-account setup in place.
    static func loadAll() -> [Account] {
        migrateLegacyDefaults()
        let d = UserDefaults.standard
        if let data = d.data(forKey: "accounts"), let list = try? JSONDecoder().decode([Account].self, from: data) {
            return list
        }
        guard let data = d.data(forKey: "account"), let single = try? JSONDecoder().decode(Account.self, from: data) else { return [] }
        saveAll([single])
        d.removeObject(forKey: "account")
        return [single]
    }

    static func saveAll(_ accounts: [Account]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: "accounts")
    }

    /// Early builds used a different bundle identifier; carry settings over once.
    private static func migrateLegacyDefaults() {
        let d = UserDefaults.standard
        guard d.data(forKey: "account") == nil, d.data(forKey: "accounts") == nil, !d.bool(forKey: "migratedLegacyDefaults"),
              let legacy = UserDefaults(suiteName: "app.letterbox.mail") else { return }
        d.set(true, forKey: "migratedLegacyDefaults")
        for key in ["account", "briefing", "aiEnabled", "aiModel", "claudePath", "blockRemoteContent", "saveToSent", "signature"] {
            if let v = legacy.object(forKey: key) { d.set(v, forKey: key) }
        }
    }
}

enum FolderRole: String {
    case inbox, drafts, sent, archive, junk, trash, custom

    var symbol: String {
        switch self {
        case .inbox: return "tray"
        case .drafts: return "doc"
        case .sent: return "paperplane"
        case .archive: return "archivebox"
        case .junk: return "xmark.bin"
        case .trash: return "trash"
        case .custom: return "folder"
        }
    }

    var order: Int {
        switch self {
        case .inbox: return 0
        case .drafts: return 2
        case .sent: return 3
        case .archive: return 4
        case .junk: return 5
        case .trash: return 6
        case .custom: return 10
        }
    }

    /// Name for the combined mailbox of this role across accounts.
    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .drafts: return "Drafts"
        case .sent: return "Sent"
        case .archive: return "Archive"
        case .junk: return "Junk"
        case .trash: return "Trash"
        case .custom: return "Folder"
        }
    }

    static let mailboxes: [FolderRole] = [.inbox, .drafts, .sent, .archive, .junk, .trash]

    /// Folders whose contents shouldn't count as "mail I received".
    var isOutgoingOrDiscarded: Bool { self == .sent || self == .drafts || self == .trash || self == .junk }

    /// Roles for one account's whole folder list.
    /// The server's own markers win: a folder that only looks like "Drafts" by name stays a plain folder
    /// when another folder is marked as the drafts mailbox (Gmail has a "Drafts" label next to "[Gmail]/Drafts").
    static func detect(_ remote: [RemoteFolder]) -> [FolderRole] {
        let marked = remote.map { marked(path: $0.path, attributes: $0.attributes) }
        let claimed = Set(marked.compactMap { $0 })
        return zip(remote, marked).map { f, role in
            if let role { return role }
            let guess = guessed(path: f.path, delimiter: f.delimiter)
            return claimed.contains(guess) ? .custom : guess
        }
    }

    /// The role the server says a folder has.
    private static func marked(path: String, attributes: Set<String>) -> FolderRole? {
        if path.uppercased() == "INBOX" { return .inbox }
        if attributes.contains("\\sent") { return .sent }
        if attributes.contains("\\drafts") { return .drafts }
        if attributes.contains("\\trash") { return .trash }
        if attributes.contains("\\junk") { return .junk }
        if attributes.contains("\\archive") || attributes.contains("\\all") { return .archive }
        return nil
    }

    /// The role a folder seems to have from its name, ignoring a wrapper such as "INBOX." or "[Gmail]/".
    private static func guessed(path: String, delimiter: String?) -> FolderRole {
        var parts = [ModifiedUTF7.decode(path)]
        if let d = delimiter, !d.isEmpty { parts = parts[0].components(separatedBy: d) }
        let name = Folder.withoutWrapper(parts).joined(separator: "/").lowercased()
        switch name {
        case "sent", "sent items", "sent messages", "sent mail", "outbox sent", "gesendet": return .sent
        case "drafts", "draft", "entwürfe": return .drafts
        case "trash", "deleted", "deleted items", "deleted messages", "bin", "papierkorb": return .trash
        case "spam", "junk", "junk e-mail", "junk mail", "bulk mail", "unwanted": return .junk
        case "archive", "archives", "archiv": return .archive
        default: return .custom
        }
    }
}

struct Folder: Identifiable, Hashable {
    /// Unique across accounts; folder paths alone repeat (every account has an INBOX).
    var id: String { MessageSummary.folderID(account, path) }
    let path: String
    var name: String
    var delimiter: String?
    var role: FolderRole
    var total: Int
    var unread: Int
    var account: String = ""

    /// The folder's name without the server's wrapper folder, so the same folder matches across accounts.
    var displayName: String {
        let short = Self.withoutWrapper(name.components(separatedBy: " / ")).joined(separator: " / ")
        switch role {
        case .inbox: return "Inbox"
        case .custom: return short
        default:
            // "SENT" or "spam" read better as "Sent" and "Spam"; "Sent Mail" stays as the server wrote it.
            let oneCase = short == short.uppercased() || short == short.lowercased()
            return oneCase ? short.prefix(1).uppercased() + short.dropFirst().lowercased() : short
        }
    }

    /// Drops a top folder that only holds the real folders: "INBOX" on servers that nest everything
    /// under it ("INBOX.Work"), and Gmail's "[Gmail]" or "[Google Mail]".
    static func withoutWrapper(_ parts: [String]) -> [String] {
        guard parts.count > 1, let top = parts.first else { return parts }
        let isWrapper = top.uppercased() == "INBOX" || (top.hasPrefix("[") && top.hasSuffix("]"))
        return isWrapper ? Array(parts.dropFirst()) : parts
    }
}

struct MessageSummary: Identifiable, Hashable {
    let folder: String
    let uid: UInt32
    var messageID: String?
    var subject: String
    var fromName: String
    var fromEmail: String
    var to: [MailAddress]
    var cc: [MailAddress]
    var replyTo: [MailAddress]
    var deliveredTo: [String]
    var date: Date
    var seen: Bool
    var flagged: Bool
    var answered: Bool
    var size: Int
    var hasAttachments: Bool
    var snippet: String
    var inReplyTo: String?
    var references: String?
    /// The id of the Letterbox account this message belongs to.
    var account: String = ""

    /// Unique across accounts.
    var id: String { account.isEmpty ? localID : "\(account)\u{2}\(localID)" }
    /// Unique within one account's cache; what that cache stores.
    var localID: String { "\(folder)\u{1}\(uid)" }
    var folderID: String { Self.folderID(account, folder) }
    static func folderID(_ account: String, _ path: String) -> String { account.isEmpty ? path : "\(account)\u{2}\(path)" }

    var sender: MailAddress { MailAddress(name: fromName, email: fromEmail) }
    var senderDisplay: String { fromName.isEmpty ? (fromEmail.isEmpty ? "Unknown Sender" : fromEmail) : fromName }
    var displaySubject: String { subject.trimmingCharacters(in: .whitespaces).isEmpty ? "(No Subject)" : subject }

    /// All addresses this message was delivered to, lowercased.
    var recipientSet: Set<String> {
        Set((to + cc).map { $0.email.lowercased() } + deliveredTo)
    }
}

struct Alias: Identifiable, Hashable {
    var id: String { "\(account)\u{2}\(email)" }
    let email: String
    var name: String
    var isPrimary: Bool
    var isManual: Bool
    var unread: Int = 0
    var account: String = ""
}

enum SidebarItem: Hashable {
    case dashboard
    /// One kind of mailbox (Inbox, Sent…) across all accounts.
    case mailbox(FolderRole)
    /// A single folder, by `Folder.id`.
    case folder(String)
    /// Custom folders with the same name across accounts, by lowercased display name.
    case folderGroup(String)
    case flagged
    case address(String)
}

// MARK: - Compact address list encoding for the cache

enum AddressCoding {
    static func encode(_ list: [MailAddress]) -> String {
        list.map { "\($0.name)\u{1F}\($0.email)" }.joined(separator: "\u{1E}")
    }

    static func decode(_ s: String) -> [MailAddress] {
        guard !s.isEmpty else { return [] }
        return s.split(separator: "\u{1E}").map { item in
            let parts = item.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            return parts.count == 2
                ? MailAddress(name: String(parts[0]), email: String(parts[1]))
                : MailAddress(name: "", email: String(item))
        }
    }
}
