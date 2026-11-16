import AppKit
import Observation
import SwiftUI

enum BodyState {
    case loading
    case loaded(ParsedMessage)
    case failed(String)
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let symbol: String
}

/// Everything Letterbox keeps per account: its settings, its own cache, and its connections.
@MainActor
final class AccountSession {
    var account: Account
    let repo: MailRepository
    let engine: SyncEngine?
    var folders: [Folder] = []

    init(account: Account, repo: MailRepository, engine: SyncEngine?) {
        self.account = account
        self.repo = repo
        self.engine = engine
    }

    var id: String { account.id }
    func folder(_ role: FolderRole) -> Folder? { folders.first { $0.role == role } }
}

@Observable @MainActor
final class ComposeDraft: Identifiable {
    let id = UUID()
    /// The account this message was started in. Set when the composer opens.
    var accountID: String?
    var fromEmail: String
    var to = ""
    var cc = ""
    var bcc = ""
    var showCcBcc = false
    var subject = ""
    var body = ""
    var attachments: [OutgoingAttachment] = []
    var inReplyTo: String?
    var references: String?
    var replyingTo: String?
    var isReply = false
    var isSending = false
    var error: String?

    /// Quoted original (reply/forward), kept apart from the editable body.
    var quote = ""
    var showQuote = false
    /// Plain text of the message being answered, for Claude.
    var context = ""
    var contextFrom = ""
    var contextSubject = ""
    var contextDate = Date()

    var aiInstruction = ""
    var aiTone: ReplyTone?
    var aiBusy = false
    var aiError: String?
    var autoGenerate = false
    @ObservationIgnored var aiTask: Task<Void, Never>?
    /// Bumps whenever the body is replaced programmatically so the editor reloads.
    var bodyRevision = 0

    init(fromEmail: String) { self.fromEmail = fromEmail }

    var isEmpty: Bool {
        to.isEmpty && cc.isEmpty && subject.isEmpty && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    var fullBody: String { quote.isEmpty ? body : body + "\n\n" + quote }
}

/// The app's view model. Mail from every account is shown together: each account keeps its own
/// cache and connections (an `AccountSession`), and the store merges what they hold.
@Observable @MainActor
final class MailStore {
    // MARK: Accounts & data
    var accounts: [Account] = []
    /// The first account added; used for greetings and as the default sender.
    var account: Account? { accounts.first }
    var multipleAccounts: Bool { accounts.count > 1 }
    var addingAccount = false
    /// Folders of every account.
    var folders: [Folder] = []
    var addresses: [Alias] = []
    var hiddenAliases: [Alias] = []
    var messages: [MessageSummary] = []
    var flaggedCount = 0

    // MARK: UI state
    var sidebarSelection: SidebarItem? = .dashboard {
        didSet {
            guard oldValue != sidebarSelection else { return }
            selection = []
            reloadMessages()
        }
    }
    var selection: Set<String> = [] {
        didSet { if oldValue != selection { selectionDidChange() } }
    }
    var searchText = "" {
        didSet { if oldValue != searchText { scheduleSearch() } }
    }
    var unreadOnly = false {
        didSet { reloadMessages() }
    }
    var bodyState: BodyState?
    var openedID: String?
    var confirmDeletion: [String]?

    /// Sidebar groups the user has shown or hidden, by `SidebarGroup.key`. Missing keys use the group's default.
    var sidebarVisibility: [String: Bool] = (UserDefaults.standard.dictionary(forKey: "sidebarVisibility") as? [String: Bool]) ?? [:] {
        didSet { UserDefaults.standard.set(sidebarVisibility, forKey: "sidebarVisibility") }
    }
    /// Sidebar groups opened to show one row per account.
    var sidebarExpanded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "sidebarExpanded") ?? ["role:inbox"]) {
        didSet { UserDefaults.standard.set(Array(sidebarExpanded), forKey: "sidebarExpanded") }
    }

    private var syncingAccounts: Set<String> = []
    var isSyncing: Bool { !syncingAccounts.isEmpty }
    var syncProgress: String?
    var lastSync: Date?
    /// Latest sync problem per account id.
    var syncErrors: [String: String] = [:]
    var syncError: String? {
        for a in accounts {
            if let e = syncErrors[a.id] { return multipleAccounts ? "\(a.email): \(e)" : e }
        }
        return nil
    }
    var toast: Toast?
    var pendingCompose: UUID?
    var drafts: [UUID: ComposeDraft] = [:]

    // MARK: Claude
    /// Claude's read on each conversation, mirrored per message id for the UI.
    var insights: [String: Insight] = [:]
    /// Keyed by `Conversation.id`.
    var threadInsights: [String: Insight] = [:]
    var conversations: [Conversation] = []
    @ObservationIgnored var threadOf: [String: String] = [:]
    @ObservationIgnored var conversationByID: [String: Conversation] = [:]
    @ObservationIgnored var knownMessages: [String: MessageSummary] = [:]
    var briefing: Briefing? = Briefing.load()
    var aiStatus: AIStatus = .unknown
    var deepSummaries: [String: DeepSummary] = [:]
    var summarizing: Set<String> = []
    var showPalette = false
    var searchFocusRequest = 0
    var pendingAsk: String?
    @ObservationIgnored let askSession = AskSession()
    var aiEnabled = UserDefaults.standard.object(forKey: "aiEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(aiEnabled, forKey: "aiEnabled"); setupAI() }
    }
    var aiModel = UserDefaults.standard.string(forKey: "aiModel") ?? "sonnet" {
        didSet { UserDefaults.standard.set(aiModel, forKey: "aiModel"); claude?.model = aiModel }
    }
    var claudePath = UserDefaults.standard.string(forKey: "claudePath") ?? "" {
        didSet { UserDefaults.standard.set(claudePath, forKey: "claudePath") }
    }
    @ObservationIgnored var claude: ClaudeCLI?
    @ObservationIgnored var triageTask: Task<Void, Never>?

    // MARK: Preferences
    var blockRemoteContent = UserDefaults.standard.bool(forKey: "blockRemoteContent") {
        didSet { UserDefaults.standard.set(blockRemoteContent, forKey: "blockRemoteContent") }
    }
    /// Repaint HTML mail in the app's theme. Each message can still be shown as the sender made it.
    var themeHTMLMail = UserDefaults.standard.object(forKey: "themeHTMLMail") as? Bool ?? true {
        didSet { UserDefaults.standard.set(themeHTMLMail, forKey: "themeHTMLMail") }
    }
    var saveToSent = UserDefaults.standard.object(forKey: "saveToSent") as? Bool ?? true {
        didSet { UserDefaults.standard.set(saveToSent, forKey: "saveToSent") }
    }
    var signature = UserDefaults.standard.string(forKey: "signature") ?? "" {
        didSet { UserDefaults.standard.set(signature, forKey: "signature") }
    }

    @ObservationIgnored private(set) var sessions: [String: AccountSession] = [:]
    /// Bumps when an account is removed so late async results that mention it are dropped.
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored var bodyCache: [String: ParsedMessage] = [:]
    @ObservationIgnored private var bodyCacheOrder: [String] = []
    @ObservationIgnored private var bodyTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private(set) var contacts: [MailAddress] = []

    /// Demo store backed by a throwaway database; used only for offscreen snapshots.
    init(demo account: Account, database: Database) {
        sessions[account.id] = AccountSession(account: account, repo: MailRepository(db: database, accountID: account.id), engine: nil)
        accounts = [account]
        loadFromCache()
        lastSync = Date()
    }

    /// Adds another demo account; used only for offscreen snapshots.
    func addDemoAccount(_ account: Account, database: Database) {
        sessions[account.id] = AccountSession(account: account, repo: MailRepository(db: database, accountID: account.id), engine: nil)
        accounts.append(account)
        loadFromCache()
    }

    init() {
        // Accounts whose password is gone from the Keychain can't connect; they're dropped like a sign-out.
        for acct in Account.loadAll() {
            guard let password = Keychain.password(for: acct.email) else { continue }
            let repo = MailRepository(db: Database(url: Database.url(forAccount: acct.id)), accountID: acct.id)
            sessions[acct.id] = AccountSession(account: acct, repo: repo, engine: SyncEngine(account: acct, password: password, repo: repo))
            accounts.append(acct)
        }
        if !accounts.isEmpty {
            loadFromCache()
            startSync()
        }
        setupAI()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: Lookups

    /// Sessions in the order the accounts were added.
    var orderedSessions: [AccountSession] { accounts.compactMap { sessions[$0.id] } }
    func session(_ accountID: String) -> AccountSession? { sessions[accountID] }

    func folder(_ role: FolderRole, in accountID: String) -> Folder? { sessions[accountID]?.folder(role) }
    func folder(of m: MessageSummary) -> Folder? { folders.first { $0.id == m.folderID } }
    var inboxes: [Folder] { folders.filter { $0.role == .inbox } }
    func isInInbox(_ m: MessageSummary) -> Bool { sessions[m.account]?.folder(.inbox)?.path == m.folder }

    /// Kinds of mailbox that exist in at least one account, for the combined list.
    var mailboxRoles: [FolderRole] { FolderRole.mailboxes.filter { r in folders.contains { $0.role == r } } }
    func mailboxTitle(_ role: FolderRole) -> String {
        role == .inbox ? "Inbox" : (folders.first { $0.role == role }?.displayName ?? role.title)
    }
    func mailboxBadge(_ role: FolderRole) -> Int {
        let list = folders.filter { $0.role == role }
        switch role {
        case .inbox, .archive: return list.reduce(0) { $0 + $1.unread }
        case .drafts: return list.reduce(0) { $0 + $1.total }
        default: return 0
        }
    }
    func customFolders(in accountID: String) -> [Folder] { folders.filter { $0.account == accountID && $0.role == .custom } }
    func addresses(in accountID: String) -> [Alias] { addresses.filter { $0.account == accountID } }
    /// Folders the given messages can be moved to: only when they all belong to one account.
    func moveTargets(for ids: [String]) -> [Folder] {
        let owners = Set(ids.compactMap(message).map(\.account))
        guard owners.count == 1, let owner = owners.first else { return [] }
        return folders.filter { $0.account == owner }
    }

    var myAddresses: Set<String> {
        Set((accounts.map(\.email) + addresses.map(\.email) + hiddenAliases.map(\.email)).map { $0.lowercased() })
    }

    /// How Claude refers to the user: their name and every account address.
    var userDescription: String {
        let name = accounts.first { !$0.displayName.isEmpty }?.displayName ?? ""
        let emails = accounts.map(\.email).joined(separator: ", ")
        return name.isEmpty ? emails : "\(name) <\(emails)>"
    }
    var userName: String {
        accounts.first { !$0.displayName.isEmpty }?.displayName ?? account?.email ?? ""
    }

    func message(_ id: String) -> MessageSummary? { messages.first { $0.id == id } ?? knownMessages[id] }
    var selectedMessages: [MessageSummary] { messages.filter { selection.contains($0.id) } }
    var openedMessage: MessageSummary? { openedID.flatMap(message) }

    var currentFolder: Folder? {
        if case .folder(let id) = sidebarSelection { return folders.first { $0.id == id } }
        return nil
    }

    /// True when the list mixes folders, so each row says where it lives.
    var showsFolderTags: Bool {
        if !searchText.isEmpty { return true }
        switch sidebarSelection {
        case .folder, .mailbox, .folderGroup: return false
        default: return true
        }
    }

    /// True while showing mail the user wrote (Sent, Drafts).
    var showingOutgoing: Bool {
        switch sidebarSelection {
        case .mailbox(let role): return role == .sent || role == .drafts
        case .folder: return currentFolder.map { $0.role == .sent || $0.role == .drafts } ?? false
        default: return false
        }
    }

    var title: String {
        if !searchText.isEmpty { return "Search" }
        switch sidebarSelection {
        case .folder(let id):
            guard let f = folders.first(where: { $0.id == id }) else { return "Mail" }
            if multipleAccounts && f.role != .custom, let email = sessions[f.account]?.account.email { return "\(f.displayName) · \(email)" }
            return f.displayName
        case .mailbox(let role): return mailboxTitle(role)
        case .folderGroup(let name): return folders(named: name).first?.displayName ?? "Mail"
        case .flagged: return "Flagged"
        case .dashboard: return "Dashboard"
        case .address(let email): return email
        case nil: return "Letterbox"
        }
    }

    var subtitle: String {
        let unread = messages.lazy.filter { !$0.seen }.count
        if !searchText.isEmpty { return "\(messages.count) results" }
        return unread == 0 ? "\(messages.count) messages" : "\(unread) unread"
    }

    /// Which of my addresses received a message. With one account the main address isn't labeled.
    func receivingAlias(for m: MessageSummary) -> String? {
        guard let s = sessions[m.account] else { return nil }
        let primary = s.account.email.lowercased()
        let recipients = m.recipientSet
        if recipients.contains(primary) { return multipleAccounts ? primary : nil }
        return addresses.first { $0.account == m.account && !$0.isPrimary && recipients.contains($0.email) }?.email
    }

    // MARK: Accounts

    /// Adds an account after checking that the server accepts the sign-in.
    func signIn(account acct: Account, password: String) async throws {
        guard !accounts.contains(where: { $0.email.lowercased() == acct.email.lowercased() }) else {
            throw IMAPError(message: "\(acct.email) is already in Letterbox.")
        }
        let repo = MailRepository(db: Database(url: Database.url(forAccount: acct.id)), accountID: acct.id)
        let candidate = SyncEngine(account: acct, password: password, repo: repo)
        do {
            try await candidate.connect()
        } catch {
            await candidate.shutdown()
            Database.removeFiles(forAccount: acct.id)
            if let error = error as? IMAPError, error.isAuthFailure {
                let hint = MailProvider.byID(acct.provider).help
                throw IMAPError(message: "The server didn’t accept that sign-in (\(error.message)). \(hint)", isAuthFailure: true)
            }
            throw error
        }
        Keychain.setPassword(password, for: acct.email)
        let session = AccountSession(account: acct, repo: repo, engine: candidate)
        sessions[acct.id] = session
        let first = accounts.isEmpty
        accounts.append(acct)
        Account.saveAll(accounts)
        addingAccount = false
        if first {
            sidebarSelection = .dashboard
            loadFromCache()
            startSync()
        } else {
            loadFromCache()
            Task { await sync(session, full: true) }
        }
    }

    /// Removes the account, its password and its downloaded mail from this Mac. Nothing on the server changes.
    func removeAccount(_ id: String) {
        guard let s = sessions.removeValue(forKey: id) else { return }
        generation += 1
        triageTask?.cancel()
        triageTask = nil
        if let engine = s.engine { Task { await engine.shutdown() } }
        Keychain.deletePassword(for: s.account.email)
        s.repo.db.wipe()
        Database.removeFiles(forAccount: id)
        accounts.removeAll { $0.id == id }
        Account.saveAll(accounts)
        syncErrors[id] = nil
        syncingAccounts.remove(id)
        for d in drafts.values where d.accountID == id { d.accountID = nil }

        if accounts.isEmpty {
            pollTask?.cancel()
            Briefing.clear()
            briefing = nil
            folders = []
            messages = []
            addresses = []
            hiddenAliases = []
            insights = [:]
            threadInsights = [:]
            conversations = []
            threadOf = [:]
            conversationByID = [:]
            knownMessages = [:]
            bodyCache = [:]
            bodyCacheOrder = []
            deepSummaries = [:]
            contacts = []
            selection = []
            sidebarSelection = .dashboard
            return
        }
        if belongsToRemovedAccount(sidebarSelection, id) { sidebarSelection = .dashboard }
        let prefix = "\(id)\u{2}"
        selection = selection.filter { !$0.hasPrefix(prefix) }
        for key in bodyCache.keys where key.hasPrefix(prefix) { bodyCache[key] = nil }
        bodyCacheOrder.removeAll { $0.hasPrefix(prefix) }
        contacts = []
        loadFromCache()
    }

    private func belongsToRemovedAccount(_ item: SidebarItem?, _ id: String) -> Bool {
        switch item {
        case .folder(let fid): return fid.hasPrefix("\(id)\u{2}")
        case .address(let email): return !addresses.contains { $0.email == email && $0.account != id }
        default: return false
        }
    }

    func updateNickname(_ name: String, for id: String) {
        guard let s = sessions[id] else { return }
        s.account.nickname = name.trimmingCharacters(in: .whitespaces)
        if let i = accounts.firstIndex(where: { $0.id == id }) { accounts[i] = s.account }
        Account.saveAll(accounts)
    }

    func updateDisplayName(_ name: String, for id: String) {
        guard let s = sessions[id] else { return }
        s.account.displayName = name
        if let i = accounts.firstIndex(where: { $0.id == id }) { accounts[i] = s.account }
        Account.saveAll(accounts)
        reloadAliases()
    }

    // MARK: Loading

    private func loadFromCache() {
        reloadFolders()
        reloadThreadInsights()
        rebuildConversations()
        reloadAliases()
        reloadMessages()
    }

    private func reloadFolders() {
        for s in orderedSessions { s.folders = s.repo.folders() }
        folders = orderedSessions.flatMap(\.folders)
    }

    func reloadThreadInsights() {
        var all: [String: Insight] = [:]
        for s in orderedSessions {
            for (key, i) in s.repo.threadInsights() { all[Conversation.globalID(account: s.id, key: key)] = i }
        }
        threadInsights = all
    }

    private static func merged(_ lists: [[MessageSummary]], limit: Int) -> [MessageSummary] {
        lists.count == 1 ? lists[0] : Array(lists.joined().sorted { $0.date > $1.date }.prefix(limit))
    }

    func reloadMessages() {
        guard let item = sidebarSelection else { messages = []; return }
        let search = searchText.trimmingCharacters(in: .whitespaces)
        if item == .dashboard && search.isEmpty {
            let since = Date().addingTimeInterval(-30 * 86400)
            messages = Self.merged(orderedSessions.map { s in
                s.folder(.inbox).map { s.repo.recentMessages(folder: $0.path, since: since, limit: 500) } ?? []
            }, limit: 500)
        } else {
            var q = MessageQuery(search: search, unreadOnly: unreadOnly)
            var targets = orderedSessions
            switch item {
            case .dashboard, .flagged:
                q.scope = item == .flagged ? .flagged : .all
                q.excludedRoles = [.trash, .junk]
            case .mailbox(let role):
                q.scope = .role(role)
                q.excludedRoles = [.trash, .junk]
            case .address(let email):
                q.scope = .address(email)
                q.excludedRoles = [.sent, .drafts, .trash, .junk]
            case .folder(let id):
                let f = folders.first { $0.id == id }
                q.scope = .folder(f?.path ?? "")
                q.excludedRoles = [.trash, .junk]
                if search.isEmpty { targets = targets.filter { $0.id == f?.account } }
            case .folderGroup(let name):
                q.excludedRoles = [.trash, .junk]
                if search.isEmpty {
                    // Same name, different path per account: one query per folder.
                    messages = Self.merged(folders(named: name).compactMap { f in
                        var fq = q
                        fq.scope = .folder(f.path)
                        return sessions[f.account]?.repo.messages(fq)
                    }, limit: q.limit)
                    break
                }
            }
            if case .folderGroup = item, search.isEmpty {} else {
                messages = Self.merged(targets.map { $0.repo.messages(q) }, limit: q.limit)
            }
        }
        let ids = Set(messages.map(\.id))
        let kept = selection.intersection(ids)
        if kept != selection { selection = kept }
    }

    /// Searches every account's cache.
    func search(_ text: String, limit: Int) -> [MessageSummary] {
        let q = MessageQuery(search: text, limit: limit)
        return Self.merged(orderedSessions.map { $0.repo.messages(q) }, limit: limit)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            reloadMessages()
        }
    }

    private func refreshCounts() {
        reloadFolders()
        flaggedCount = orderedSessions.reduce(0) { $0 + $1.repo.flaggedCount() }
        for i in addresses.indices {
            guard let s = sessions[addresses[i].account] else { continue }
            let excluded = s.folders.filter { $0.role.isOutgoingOrDiscarded }.map(\.path)
            addresses[i].unread = s.repo.unreadCount(forAddress: addresses[i].email, excluding: excluded)
        }
    }

    private func didUpdate(_ folder: Folder) {
        refreshCounts()
        let affected: Bool
        switch sidebarSelection {
        case .folder(let id): affected = id == folder.id || !searchText.isEmpty
        case .mailbox(let role): affected = role == folder.role || !searchText.isEmpty
        case .folderGroup(let name): affected = (folder.role == .custom && folder.displayName.lowercased() == name) || !searchText.isEmpty
        case .flagged, .address, .dashboard: affected = true
        case nil: affected = false
        }
        if affected { reloadMessages() }
    }

    // MARK: Aliases

    func reloadAliases() {
        let accountEmails = Set(accounts.map { $0.email.lowercased() })
        var shown: [Alias] = []
        var hidden: [Alias] = []
        for s in orderedSessions {
            let primary = Alias(email: s.account.email.lowercased(), name: s.account.displayName, isPrimary: true, isManual: false, account: s.id)
            // Another account's address is never an alias of this one.
            let stored = s.repo.storedAliases().filter { !accountEmails.contains($0.email) }
            let make = { (a: (email: String, name: String, source: String, hidden: Bool)) in
                Alias(email: a.email, name: a.name, isPrimary: false, isManual: a.source == "manual", account: s.id)
            }
            shown += [primary] + stored.filter { !$0.hidden }.map(make).sorted { $0.email < $1.email }
            hidden += stored.filter { $0.hidden }.map(make)
        }
        addresses = shown
        hiddenAliases = hidden
        refreshCounts()
    }

    private func detectAliases(_ s: AccountSession) async {
        let sent = s.folder(.sent)?.path
        let excluded = s.folders.filter { $0.role.isOutgoingOrDiscarded }.map(\.path)
        let repo = s.repo
        let primary = s.account.email
        let others = Set(accounts.filter { $0.id != s.id }.map { $0.email.lowercased() })
        let candidates = await Task.detached(priority: .utility) {
            AliasDetector.detect(repo.aliasEvidence(sentFolder: sent, receivedExcluding: excluded), primary: primary)
        }.value
        for c in candidates where !others.contains(c.email) { repo.saveAlias(email: c.email, name: c.name, source: "detected") }
        guard sessions[s.id] === s else { return }
        reloadAliases()
    }

    func addAlias(_ email: String, name: String = "", to accountID: String) {
        let clean = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard clean.contains("@"), !accounts.contains(where: { $0.email.lowercased() == clean }), let s = sessions[accountID] else { return }
        s.repo.saveAlias(email: clean, name: name, source: "manual")
        s.repo.setAliasHidden(clean, hidden: false)
        reloadAliases()
    }

    private func owner(ofAlias email: String) -> AccountSession? {
        (addresses + hiddenAliases).first { $0.email == email.lowercased() }.flatMap { sessions[$0.account] }
    }

    func setAlias(_ email: String, hidden: Bool) {
        owner(ofAlias: email)?.repo.setAliasHidden(email, hidden: hidden)
        if hidden, sidebarSelection == .address(email) { sidebarSelection = .mailbox(.inbox) }
        reloadAliases()
    }

    func renameAlias(_ email: String, to name: String) {
        owner(ofAlias: email)?.repo.renameAlias(email, name: name)
        reloadAliases()
    }

    // MARK: Sync

    private func startSync() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.syncAll(full: true)
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                tick += 1
                await self?.syncAll(full: tick % 5 == 0)
            }
        }
    }

    func refresh() {
        Task { await syncAll(full: true) }
    }

    /// Syncs every account at the same time.
    func syncAll(full: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for s in orderedSessions {
                group.addTask { @MainActor [weak self] in await self?.sync(s, full: full) }
            }
        }
    }

    func sync(_ s: AccountSession, full: Bool, extra: [String] = []) async {
        let id = s.id
        guard let engine = s.engine, !syncingAccounts.contains(id) else { return }
        syncingAccounts.insert(id)
        defer {
            syncingAccounts.remove(id)
            if syncingAccounts.isEmpty { syncProgress = nil }
        }
        let alive = { [weak self] in self?.sessions[id] === s }
        do {
            if full || s.folders.isEmpty {
                try await engine.refreshFolders()
                guard alive() else { return }
                refreshCounts()
            }
            var order: [Folder] = []
            if let inbox = s.folder(.inbox) { order.append(inbox) }
            if full {
                order += s.folders.filter { $0.role != .inbox }.sorted { ($0.role == .sent ? 0 : 1) < ($1.role == .sent ? 0 : 1) }
            } else {
                if let current = currentFolder, current.account == id, current.role != .inbox { order.append(current) }
                if case .mailbox(let role) = sidebarSelection, let f = s.folder(role), !order.contains(f) { order.append(f) }
                if case .folderGroup(let name) = sidebarSelection {
                    order += s.folders.filter { $0.role == .custom && $0.displayName.lowercased() == name && !order.contains($0) }
                }
                order += s.folders.filter { extra.contains($0.path) && !order.contains($0) }
            }
            for f in order {
                guard alive() else { return }
                let window: Int
                switch f.role {
                case .inbox: window = 2000
                case .trash, .junk: window = 200
                default: window = 600
                }
                let isFirst = s.repo.uidRange(f.path) == nil
                let name = multipleAccounts ? "\(f.displayName) (\(s.account.email))" : f.displayName
                let changed = try await engine.syncFolder(f.path, initialWindow: window) { [weak self] done, total in
                    guard let self, alive() else { return }
                    if isFirst { self.syncProgress = "Downloading \(name) — \(done) of \(total)" }
                    self.didUpdate(f)
                }
                if changed && alive() { didUpdate(f) }
            }
            guard alive() else { return }
            refreshCounts()
            rebuildConversations()
            await detectAliases(s)
            guard alive() else { return }
            if let inbox = s.folder(.inbox) {
                try await engine.prefetchBodies(in: inbox.path, limit: full ? 150 : 40) { [weak self] in
                    guard let self, alive() else { return }
                    self.didUpdate(inbox)
                }
            }
            if let sent = s.folder(.sent) {
                try await engine.prefetchBodies(in: sent.path, limit: full ? 80 : 20) {}
            }
            guard alive() else { return }
            lastSync = Date()
            syncErrors[id] = nil
            scheduleTriage()
        } catch {
            if alive() { syncErrors[id] = Self.friendly(error) }
        }
    }

    static func friendly(_ error: Error) -> String {
        if let e = error as? IMAPError, e.isAuthFailure {
            return "Your mail server rejected the sign-in. If you use two-factor authentication, you may need an app password."
        }
        if error is NetError || (error as NSError).domain == NSPOSIXErrorDomain || (error as NSError).domain == "Network.NWError" {
            return "Can’t reach your mail server right now. Letterbox will keep trying."
        }
        return error.localizedDescription
    }

    // MARK: Reading

    private func selectionDidChange() {
        guard selection.count == 1, let id = selection.first, let m = message(id) else {
            openedID = nil
            bodyState = nil
            return
        }
        open(m)
    }

    private func open(_ m: MessageSummary) {
        openedID = m.id
        bodyTask?.cancel()
        if let cached = bodyCache[m.id] {
            bodyState = .loaded(cached)
            prefetchNeighbors(of: m)
        } else {
            bodyState = .loading
            let s = sessions[m.account]
            bodyTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let (parsed, snippet): (ParsedMessage, String)
                    if let engine = s?.engine {
                        (parsed, snippet) = try await engine.loadBody(folder: m.folder, uid: m.uid)
                    } else if let raw = s?.repo.body(folder: m.folder, uid: m.uid) {
                        let p = MessageParser.parse(raw)
                        (parsed, snippet) = (p, p.snippet)
                    } else {
                        throw IMAPError(message: "Not connected.")
                    }
                    guard self.sessions[m.account] != nil else { return }
                    self.remember(parsed, for: m.id)
                    self.updateLocal(m.id) { if $0.snippet.isEmpty { $0.snippet = snippet } }
                    guard self.openedID == m.id else { return }
                    self.bodyState = .loaded(parsed)
                    self.prefetchNeighbors(of: m)
                } catch {
                    guard self.openedID == m.id, !Task.isCancelled else { return }
                    self.bodyState = .failed(Self.friendly(error))
                }
            }
        }
        if !m.seen { applyFlag([m.id], column: "seen", flag: "\\Seen", value: true) }
    }

    func retryOpen() {
        if let m = openedMessage { open(m) }
    }

    private func remember(_ parsed: ParsedMessage, for id: String) {
        if bodyCache[id] == nil { bodyCacheOrder.append(id) }
        bodyCache[id] = parsed
        while bodyCacheOrder.count > 40 {
            bodyCache[bodyCacheOrder.removeFirst()] = nil
        }
    }

    /// Warms the next and previous messages so arrow-key navigation feels instant.
    private func prefetchNeighbors(of m: MessageSummary) {
        guard let idx = messages.firstIndex(where: { $0.id == m.id }) else { return }
        let neighbors = [idx + 1, idx - 1].filter { messages.indices.contains($0) }.map { messages[$0] }
        for n in neighbors where bodyCache[n.id] == nil && n.size < 2_000_000 {
            guard let engine = sessions[n.account]?.engine else { continue }
            Task { [weak self] in
                guard let (parsed, snippet) = try? await engine.loadBody(folder: n.folder, uid: n.uid), self?.sessions[n.account] != nil else { return }
                self?.remember(parsed, for: n.id)
                self?.updateLocal(n.id) { if $0.snippet.isEmpty { $0.snippet = snippet } }
            }
        }
    }

    private func updateLocal(_ id: String, _ change: (inout MessageSummary) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[i])
    }

    /// Groups messages by account, then by folder, for calls that go to one server folder at a time.
    private func byAccountAndFolder(_ list: [MessageSummary]) -> [(session: AccountSession, folder: String, messages: [MessageSummary])] {
        var out: [(AccountSession, String, [MessageSummary])] = []
        for (acct, group) in Dictionary(grouping: list, by: \.account) {
            guard let s = sessions[acct] else { continue }
            for (folder, inFolder) in Dictionary(grouping: group, by: \.folder) { out.append((s, folder, inFolder)) }
        }
        return out
    }

    // MARK: Flags

    func applyRead(_ ids: [String]) {
        applyFlag(ids, column: "seen", flag: "\\Seen", value: true)
    }

    func toggleRead(_ ids: [String]) {
        let targets = ids.compactMap(message)
        let makeRead = targets.contains { !$0.seen }
        applyFlag(ids, column: "seen", flag: "\\Seen", value: makeRead)
    }

    func toggleFlag(_ ids: [String]) {
        let targets = ids.compactMap(message)
        let makeFlagged = targets.contains { !$0.flagged }
        applyFlag(ids, column: "flagged", flag: "\\Flagged", value: makeFlagged)
    }

    private func applyFlag(_ ids: [String], column: String, flag: String, value: Bool) {
        let targets = ids.compactMap(message).filter { m in
            switch column {
            case "seen": return m.seen != value
            case "flagged": return m.flagged != value
            default: return m.answered != value
            }
        }
        guard !targets.isEmpty else { return }
        for (s, folder, group) in byAccountAndFolder(targets) {
            let uids = group.map(\.uid)
            s.repo.setFlag(column, value, folder: folder, uids: uids)
            if column == "seen" { s.repo.adjustUnread(folder, by: value ? -uids.count : uids.count) }
            let engine = s.engine
            Task { [weak self] in
                do { try await engine?.setFlag(flag, value, folder: folder, uids: uids) } catch { self?.show(error) }
            }
        }
        for m in targets {
            updateLocal(m.id) {
                switch column {
                case "seen": $0.seen = value
                case "flagged": $0.flagged = value
                default: $0.answered = value
                }
            }
        }
        refreshCounts()
    }

    // MARK: Moving

    /// Moves messages to a folder chosen per account (each message stays in its own account).
    /// Returns how many messages moved.
    @discardableResult
    private func moveMessages(_ targets: [MessageSummary], destination: (AccountSession) -> String?) -> Int {
        var moving: [MessageSummary] = []
        var jobs: [(AccountSession, String, [UInt32], String)] = []
        for (acct, group) in Dictionary(grouping: targets, by: \.account) {
            guard let s = sessions[acct], let dest = destination(s) else { continue }
            let list = group.filter { $0.folder != dest }
            moving += list
            for (folder, inFolder) in Dictionary(grouping: list, by: \.folder) { jobs.append((s, folder, inFolder.map(\.uid), dest)) }
        }
        guard !moving.isEmpty else { return 0 }
        removeLocally(moving)
        for (s, folder, uids, dest) in jobs {
            let engine = s.engine
            Task { [weak self] in
                do {
                    try await engine?.move(folder: folder, uids: uids, to: dest)
                } catch {
                    self?.show(error)
                    await self?.sync(s, full: false, extra: [folder])
                }
            }
        }
        return moving.count
    }

    /// Moves each message to its own account's folder of the given kind (Inbox, Archive, Trash…).
    func move(_ ids: [String], toRole role: FolderRole, label: String? = nil, symbol: String? = nil) {
        let n = moveMessages(ids.compactMap(message)) { $0.folder(role)?.path }
        guard n > 0 else { return }
        showToast(label ?? "Moved to \(mailboxTitle(role))", symbol: symbol ?? role.symbol + ".fill")
    }

    func move(_ ids: [String], to folder: Folder, label: String? = nil, symbol: String = "folder.fill") {
        let n = moveMessages(ids.compactMap(message).filter { $0.account == folder.account }) { $0.id == folder.account ? folder.path : nil }
        guard n > 0 else { return }
        showToast(label ?? "Moved to \(folder.displayName)", symbol: symbol)
    }

    /// Moves each message to its own account's custom folder with this name, where there is one.
    func move(_ ids: [String], toFolderNamed name: String) {
        let n = moveMessages(ids.compactMap(message)) { s in
            s.folders.first { $0.role == .custom && $0.displayName.lowercased() == name }?.path
        }
        guard n > 0, let title = folders(named: name).first?.displayName else { return }
        showToast("Moved to \(title)", symbol: "folder.fill")
    }

    func archive(_ ids: [String]) {
        let targets = ids.compactMap(message)
        let missing = Set(targets.map(\.account)).filter { folder(.archive, in: $0) == nil }
        guard !missing.isEmpty else {
            move(ids, toRole: .archive, label: "Archived", symbol: "archivebox.fill")
            return
        }
        Task {
            for acct in missing {
                guard let engine = sessions[acct]?.engine else { continue }
                do {
                    try await engine.createFolder("Archive")
                    try await engine.refreshFolders()
                } catch { show(error) }
            }
            refreshCounts()
            move(ids, toRole: .archive, label: "Archived", symbol: "archivebox.fill")
        }
    }

    func trash(_ ids: [String]) {
        let targets = ids.compactMap(message)
        guard !targets.isEmpty else { return }
        let inTrashOrNoTrash = { (m: MessageSummary) in
            guard let t = self.folder(.trash, in: m.account) else { return true }
            return m.folder == t.path
        }
        if targets.allSatisfy(inTrashOrNoTrash) {
            confirmDeletion = ids
            return
        }
        let movable = targets.filter { !inTrashOrNoTrash($0) }
        move(movable.map(\.id), toRole: .trash,
             label: movable.count == 1 ? "Moved to Trash" : "Moved \(movable.count) messages to Trash", symbol: "trash.fill")
    }

    func markJunk(_ ids: [String]) {
        let targets = ids.compactMap(message)
        let allJunk = !targets.isEmpty && targets.allSatisfy { folder(.junk, in: $0.account)?.path == $0.folder }
        if allJunk {
            move(ids, toRole: .inbox, label: "Moved to Inbox", symbol: "tray.fill")
        } else {
            move(ids, toRole: .junk, label: "Marked as Junk", symbol: "xmark.bin.fill")
        }
    }

    func moveToInbox(_ ids: [String]) {
        move(ids, toRole: .inbox, label: "Moved to Inbox", symbol: "tray.fill")
    }

    func deleteConfirmed() {
        guard let ids = confirmDeletion else { return }
        confirmDeletion = nil
        let targets = ids.compactMap(message)
        removeLocally(targets)
        showToast(targets.count == 1 ? "Message deleted" : "\(targets.count) messages deleted", symbol: "trash.fill")
        for (s, folder, group) in byAccountAndFolder(targets) {
            let uids = group.map(\.uid)
            let engine = s.engine
            Task { [weak self] in
                do { try await engine?.deletePermanently(folder: folder, uids: uids) } catch { self?.show(error) }
            }
        }
    }

    private func removeLocally(_ targets: [MessageSummary]) {
        let ids = Set(targets.map(\.id))
        let firstIndex = messages.firstIndex { ids.contains($0.id) }
        for (s, folder, group) in byAccountAndFolder(targets) {
            s.repo.delete(folder: folder, uids: group.map(\.uid))
            let unread = group.filter { !$0.seen }.count
            if unread > 0 { s.repo.adjustUnread(folder, by: -unread) }
        }
        withAnimation(.snappy(duration: 0.22)) {
            messages.removeAll { ids.contains($0.id) }
        }
        if let firstIndex, !messages.isEmpty, selection.isSubset(of: ids) || selection.isEmpty {
            selection = [messages[min(firstIndex, messages.count - 1)].id]
        } else {
            selection.subtract(ids)
        }
        refreshCounts()
    }

    // MARK: Composing

    func requestCompose(_ draft: ComposeDraft) {
        if !signature.isEmpty && !draft.body.contains(signature) {
            draft.body += "\n\n-- \n\(signature)"
        }
        if draft.accountID == nil { draft.accountID = sendingSession(for: draft)?.id }
        drafts[draft.id] = draft
        pendingCompose = draft.id
        if contacts.isEmpty { loadContacts() }
    }

    func newMessage(from email: String? = nil, to: String = "", subject: String = "", body: String = "") {
        let d = ComposeDraft(fromEmail: email ?? defaultFromAddress)
        d.to = to
        d.subject = subject
        d.body = body
        requestCompose(d)
    }

    private var defaultFromAddress: String {
        switch sidebarSelection {
        case .address(let email): return email
        case .folder(let id):
            if let f = folders.first(where: { $0.id == id }), let s = sessions[f.account] { return s.account.email }
        default: break
        }
        return account?.email ?? ""
    }

    @discardableResult
    func reply(all: Bool, to target: MessageSummary? = nil) -> ComposeDraft? {
        guard let m = target ?? openedMessage ?? selectedMessages.first else { return nil }
        let parsed = bodyCache[m.id]
        let me = myAddresses
        let d = ComposeDraft(fromEmail: replyAddress(for: m))
        d.accountID = m.account
        let primaryTargets = m.replyTo.isEmpty ? [m.sender] : m.replyTo
        var to = primaryTargets
        var cc: [MailAddress] = []
        if all {
            to += m.to.filter { !me.contains($0.email.lowercased()) }
            cc = m.cc.filter { !me.contains($0.email.lowercased()) }
        }
        to = unique(to)
        if to.isEmpty { to = m.to }
        d.to = to.map(MessageBuilder.format).joined(separator: ", ")
        if !cc.isEmpty { d.cc = unique(cc).map(MessageBuilder.format).joined(separator: ", "); d.showCcBcc = true }
        d.subject = Self.prefixed("Re:", m.subject)
        d.inReplyTo = m.messageID
        d.references = [m.references, m.messageID].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        d.replyingTo = m.id
        d.isReply = true
        let original = parsed?.quotableText ?? m.snippet
        let quoted = original
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }
            .joined(separator: "\n")
        d.quote = "On \(RelativeDate.detailed(m.date)), \(m.senderDisplay) wrote:\n\(quoted)"
        d.context = original
        d.contextFrom = MessageBuilder.format(m.sender)
        d.contextSubject = m.displaySubject
        d.contextDate = m.date
        requestCompose(d)
        return d
    }

    func forward() {
        guard let m = openedMessage ?? selectedMessages.first else { return }
        let parsed = bodyCache[m.id]
        let d = ComposeDraft(fromEmail: replyAddress(for: m))
        d.accountID = m.account
        d.subject = Self.prefixed("Fwd:", m.subject)
        d.isReply = true
        d.context = parsed?.quotableText ?? m.snippet
        d.contextFrom = MessageBuilder.format(m.sender)
        d.contextSubject = m.displaySubject
        d.contextDate = m.date
        d.quote = """
        ---------- Forwarded message ----------
        From: \(MessageBuilder.format(m.sender))
        Date: \(RelativeDate.detailed(m.date))
        Subject: \(m.displaySubject)
        To: \(m.to.map(MessageBuilder.format).joined(separator: ", "))

        \(parsed?.quotableText ?? m.snippet)
        """
        d.attachments = (parsed?.attachments ?? []).map { OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data) }
        requestCompose(d)
    }

    func compose(mailto url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        var to = comps.path
        var subject = "", body = "", cc = ""
        for item in comps.queryItems ?? [] {
            switch item.name.lowercased() {
            case "subject": subject = item.value ?? ""
            case "body": body = item.value ?? ""
            case "cc": cc = item.value ?? ""
            case "to": to += (to.isEmpty ? "" : ", ") + (item.value ?? "")
            default: break
            }
        }
        let d = ComposeDraft(fromEmail: openedMessage.map(replyAddress) ?? defaultFromAddress)
        d.to = to
        d.cc = cc
        d.showCcBcc = !cc.isEmpty
        d.subject = subject
        d.body = body
        requestCompose(d)
    }

    /// Replies go out from whichever address of the message's account received the original.
    func replyAddress(for m: MessageSummary) -> String {
        guard let s = sessions[m.account] else { return account?.email ?? "" }
        let primary = s.account.email.lowercased()
        let mine = Set(addresses(in: m.account).map(\.email))
        let ordered = m.to.map { $0.email.lowercased() } + m.cc.map { $0.email.lowercased() } + m.deliveredTo
        if ordered.contains(primary) { return primary }
        if m.folder == s.folder(.sent)?.path, mine.contains(m.fromEmail.lowercased()) { return m.fromEmail.lowercased() }
        return ordered.first { mine.contains($0) } ?? primary
    }

    private func unique(_ list: [MailAddress]) -> [MailAddress] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.email.lowercased()).inserted }
    }

    private static func prefixed(_ prefix: String, _ subject: String) -> String {
        let lower = subject.lowercased()
        let existing = prefix == "Re:" ? ["re:", "aw:", "sv:"] : ["fwd:", "fw:", "wg:"]
        return existing.contains(where: lower.hasPrefix) ? subject : "\(prefix) \(subject)"
    }

    func loadContacts() {
        var seen = Set<String>()
        let sent = orderedSessions.flatMap { s in s.folder(.sent).map { s.repo.sentRecipients(sentFolder: $0.path) } ?? [] }
        let received = orderedSessions.flatMap { $0.repo.contacts() }
        contacts = (sent + received).filter {
            let key = $0.email.lowercased()
            return !key.contains("noreply") && !key.contains("no-reply") && seen.insert(key).inserted
        }
    }

    /// The account a draft goes out through: the one that owns its From address, else the one it was started in.
    private func sendingSession(for d: ComposeDraft) -> AccountSession? {
        let email = d.fromEmail.lowercased()
        if let a = accounts.first(where: { $0.email.lowercased() == email }) { return sessions[a.id] }
        if let alias = (addresses + hiddenAliases).first(where: { $0.email == email }) { return sessions[alias.account] }
        if let id = d.accountID, let s = sessions[id] { return s }
        return account.flatMap { sessions[$0.id] }
    }

    /// Every address the composer can send from, grouped by account.
    var fromAddresses: [String] {
        var seen = Set<String>()
        return addresses.map(\.email).filter { seen.insert($0).inserted }
    }

    /// The name shown next to a From address.
    func senderName(for fromEmail: String) -> String {
        guard let alias = addresses.first(where: { $0.email == fromEmail.lowercased() }) else { return account?.displayName ?? "" }
        if !alias.name.isEmpty { return alias.name }
        return sessions[alias.account]?.account.displayName ?? ""
    }

    func send(_ d: ComposeDraft) async -> Bool {
        guard let session = sendingSession(for: d), let engine = session.engine else {
            d.error = "This account isn’t connected."
            return false
        }
        let account = session.account
        d.error = nil
        let to = MailAddress.parseList(d.to), cc = MailAddress.parseList(d.cc), bcc = MailAddress.parseList(d.bcc)
        let typed = [d.to, d.cc, d.bcc].flatMap { $0.split(separator: ",") }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        guard !(to + cc + bcc).isEmpty else { d.error = "Add at least one recipient."; return false }
        guard typed == (to + cc + bcc).count else { d.error = "One of the addresses doesn’t look right."; return false }

        let outgoing = OutgoingMessage(from: MailAddress(name: senderName(for: d.fromEmail), email: d.fromEmail), to: to, cc: cc, bcc: bcc,
                                       subject: d.subject, body: d.fullBody, inReplyTo: d.inReplyTo, references: d.references,
                                       attachments: d.attachments)
        let (bytes, _) = MessageBuilder.build(outgoing)
        d.isSending = true
        defer { d.isSending = false }
        do {
            try await engine.smtp().send(bytes, from: d.fromEmail, to: outgoing.allRecipients)
        } catch {
            d.error = error.localizedDescription
            return false
        }
        var extra: [String] = []
        if saveToSent, account.serverSavesSent == false, let sent = session.folder(.sent) {
            try? await engine.append(to: sent.path, message: bytes, flags: ["\\Seen"])
            extra.append(sent.path)
        }
        if let rid = d.replyingTo, message(rid) != nil {
            applyFlag([rid], column: "answered", flag: "\\Answered", value: true)
        }
        showToast("Message sent", symbol: "paperplane.fill")
        drafts[d.id] = nil
        if sessions[session.id] === session { Task { await sync(session, full: false, extra: extra) } }
        return true
    }

    // MARK: Attachments

    func open(_ a: Attachment) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Letterbox/\(a.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Self.safeFilename(a.filename))
        do {
            try a.data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch { show(error) }
    }

    func save(_ a: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.safeFilename(a.filename)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try a.data.write(to: url) } catch { show(error) }
    }

    private static func safeFilename(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Attachment" : cleaned
    }

    // MARK: Feedback

    func showToast(_ message: String, symbol: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = Toast(message: message, symbol: symbol) }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

    func show(_ error: Error) {
        showToast(Self.friendly(error), symbol: "exclamationmark.triangle.fill")
    }
}
