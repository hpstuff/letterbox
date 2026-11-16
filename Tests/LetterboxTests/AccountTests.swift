import XCTest
@testable import Letterbox

final class AccountTests: XCTestCase {
    func testLegacyAccountKeepsItsCacheAndBriefing() throws {
        // Saved by single-account builds: no id field.
        let json = #"{"email":"me@example.com","displayName":"Me","imapHost":"imap.example.com"}"#
        let a = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        XCTAssertEqual(a.id, Account.legacyID)
        XCTAssertEqual(Database.url(forAccount: a.id).lastPathComponent, "mail.sqlite")
    }

    func testNewAccountsGetTheirOwnCache() throws {
        let a = Account(email: "a@example.com", displayName: "")
        let b = Account(email: "b@example.com", displayName: "")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(Database.url(forAccount: a.id), Database.url(forAccount: b.id))
        XCTAssertNotEqual(Database.url(forAccount: a.id).lastPathComponent, "mail.sqlite")
        XCTAssertEqual(a.label, "a@example.com")
    }

    func testAccountListRoundTripsWithIDs() throws {
        let list = [Account(email: "a@example.com", displayName: "A"), Account(email: "b@example.com", displayName: "B")]
        let decoded = try JSONDecoder().decode([Account].self, from: JSONEncoder().encode(list))
        XCTAssertEqual(decoded, list)
    }

    func testMessagesFromTwoAccountsNeverShareAnID() throws {
        let dir = FileManager.default.temporaryDirectory
        let a = MailRepository(db: Database(url: dir.appendingPathComponent("lb-a-\(UUID()).sqlite")), accountID: "A")
        let b = MailRepository(db: Database(url: dir.appendingPathComponent("lb-b-\(UUID()).sqlite")), accountID: "B")
        for repo in [a, b] {
            repo.replaceFolders([RemoteFolder(path: "INBOX", delimiter: "/", attributes: []),
                                 RemoteFolder(path: "Sent", delimiter: "/", attributes: ["\\sent"])])
            repo.upsert([FetchedSummary(uid: 1, date: Date(), subject: "Hello")], folder: "INBOX")
            repo.upsert([FetchedSummary(uid: 1, date: Date(), subject: "Re: Hello")], folder: "Sent")
        }
        let inboxA = a.messages(MessageQuery(scope: .role(.inbox)))
        let inboxB = b.messages(MessageQuery(scope: .role(.inbox)))
        XCTAssertEqual(inboxA.count, 1)
        XCTAssertEqual(inboxA[0].account, "A")
        XCTAssertNotEqual(inboxA[0].id, inboxB[0].id, "Same folder and UID in two accounts must stay distinct")
        XCTAssertEqual(inboxA[0].localID, inboxB[0].localID)
        XCTAssertEqual(a.messages(MessageQuery(scope: .role(.sent))).map(\.subject), ["Re: Hello"])
        XCTAssertNotEqual(a.folders()[0].id, b.folders()[0].id)
    }

    func testConversationIDsArePerAccountButKeysAreNot() {
        let m = MessageSummary(folder: "INBOX", uid: 1, messageID: "<x@y>", subject: "Hi", fromName: "", fromEmail: "ann@x.com",
                               to: [], cc: [], replyTo: [], deliveredTo: [], date: Date(), seen: true, flagged: false, answered: false,
                               size: 1, hasAttachments: false, snippet: "", inReplyTo: nil, references: nil)
        var inA = m; inA.account = "A"
        var inB = m; inB.account = "B"
        let a = ThreadBuilder.build([inA], me: [], sentFolder: nil, account: "A")[0]
        let b = ThreadBuilder.build([inB], me: [], sentFolder: nil, account: "B")[0]
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.key, "x@y", "Stored insight keys stay the same as before multiple accounts")
        XCTAssertEqual(a.key, b.key)
    }
}
