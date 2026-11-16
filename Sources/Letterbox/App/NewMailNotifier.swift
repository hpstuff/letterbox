import AppKit
import UserNotifications

/// Posts macOS notifications for new mail, keeps the Dock badge in step with
/// unread mail, and opens the message when a notification is clicked.
@MainActor
final class NewMailNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NewMailNotifier()

    weak var store: MailStore?
    /// Opens the main window when it was closed. Set by the window's root view.
    var openMainWindow: (() -> Void)?

    /// Notifications need a real app bundle; `swift run` and tests have none.
    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
    private var center: UNUserNotificationCenter? { available ? .current() : nil }

    /// Most banners posted for one sync. Beyond that, one summary banner is posted instead.
    private static let maxBanners = 3

    func start() {
        guard let center else { return }
        center.delegate = self
        requestPermissionIfWanted()
    }

    func requestPermissionIfWanted() {
        guard let center, store?.notifyNewMail ?? true else { return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: Posting

    struct Arrival {
        let account: String
        let accountEmail: String
        let folder: String
        let uid: UInt32
        let sender: String
        let subject: String
    }

    func notify(_ arrivals: [Arrival], showAccount: Bool) {
        guard let center, !arrivals.isEmpty, store?.notifyNewMail ?? false else { return }
        // The list already shows new mail when Letterbox is in front.
        guard !NSApp.isActive else { return }

        if arrivals.count > Self.maxBanners {
            let content = UNMutableNotificationContent()
            content.title = "\(arrivals.count) new messages"
            content.body = Array(Set(arrivals.map(\.sender))).sorted().prefix(4).joined(separator: ", ")
            content.sound = .default
            content.threadIdentifier = "new-mail"
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return
        }
        for (i, a) in arrivals.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = a.sender
            content.subtitle = showAccount ? a.accountEmail : ""
            content.body = a.subject
            if i == 0 { content.sound = .default }
            content.threadIdentifier = a.account
            content.userInfo = ["account": a.account, "folder": a.folder, "uid": Int(a.uid)]
            let id = "\(a.account)\u{1}\(a.folder)\u{1}\(a.uid)"
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// Removes banners for messages the user has read or that are gone.
    func withdraw(account: String, folder: String, uids: [UInt32]) {
        guard let center, !uids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: uids.map { "\(account)\u{1}\(folder)\u{1}\($0)" })
    }

    // MARK: Dock badge

    func updateBadge(unread: Int) {
        let label = (store?.dockBadge ?? false) && unread > 0 ? (unread > 999 ? "999+" : "\(unread)") : nil
        if NSApplication.shared.dockTile.badgeLabel != label { NSApplication.shared.dockTile.badgeLabel = label }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let account = info["account"] as? String
        let folder = info["folder"] as? String
        let uid = (info["uid"] as? Int).map(UInt32.init)
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { openMainWindow?() }
            if let account, let folder, let uid {
                store?.showMessage(account: account, folder: folder, uid: uid)
            } else {
                store?.sidebarSelection = .mailbox(.inbox)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
