import XCTest
@testable import WildcatGames
import WildcatRadioCore

/// Reticulum (beta) in the app: the model between the bridge's events, the saved book, the block
/// list and the screens. The rules themselves are tested in the core (ReticulumTests, ReticulumBookTests).
@MainActor
final class ReticulumModelTests: XCTestCase {
    private let maya = String(repeating: "a1", count: 16)
    private let sam = String(repeating: "b2", count: 16)
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "reticulum-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func model(book: URL? = nil) -> ReticulumModel {
        let m = ReticulumModel(defaults: defaults, bookURL: book)
        m.notify = { _, _, _ in }
        return m
    }

    private func started(_ m: ReticulumModel) {
        m.apply(.started(.init(address: "221b", identityHash: "ebf8", rns: "1.5.7", lxmf: "1.2.0", crypto: "openssl", python: "3.13.16",
                               reticulumMs: 105, lxmfMs: 4)))
    }

    private func incoming(_ id: String, from peer: String, _ text: String, trust: Reticulum.Trust = .verified) -> Reticulum.Event {
        .message(.init(id: id, incoming: true, peer: peer, text: text, at: Date(), delivery: .received, trust: trust, read: false))
    }

    func testEventsBuildTheScreen() {
        let s = model()
        started(s)
        XCTAssertEqual(s.phase, .running)
        XCTAssertEqual(s.address, "221b")
        XCTAssertEqual(s.versions, "RNS 1.5.7 · LXMF 1.2.0 · Python 3.13.16 · openssl")
        s.apply(.announce(.init(hash: maya, name: "MAYA", hops: 1, at: Date(timeIntervalSince1970: 1))))
        s.apply(.announce(.init(hash: sam, name: "SAM", hops: 2, at: Date(timeIntervalSince1970: 2))))
        s.apply(.announce(.init(hash: maya, name: nil, hops: 1, at: Date(timeIntervalSince1970: 3))))
        XCTAssertEqual(s.heard.map(\.hash), [maya, sam], "the most recent first")
        XCTAssertEqual(s.title(for: maya), "MAYA")
        // A sent message moves through its states.
        s.apply(.message(.init(id: "m1", incoming: false, peer: maya, text: "hi", at: Date(), delivery: .queued)))
        s.apply(.messageState(id: "m1", delivery: .sending, failure: nil, detail: nil))
        s.apply(.messageState(id: "m1", delivery: .delivered, failure: nil, detail: nil))
        XCTAssertEqual(s.thread(with: maya).map(\.delivery), [.delivered])
        s.apply(incoming("h1", from: maya, "echo: hi"))
        XCTAssertEqual(s.thread(with: maya).map(\.id), ["m1", "h1"])
        XCTAssertEqual(s.unread, 1)
        s.openPeer = maya
        XCTAssertEqual(s.unread, 0, "opening the chat reads it")
        s.apply(incoming("h2", from: maya, "more"))
        XCTAssertEqual(s.unread, 0, "read as it arrives while the chat is open")
        // An interface list says whether the radio is up.
        s.apply(.interfaces([.init(name: "WildcatRNodeInterface[RNode over Bluetooth]", online: true)]))
        XCTAssertTrue(s.radioOnline)
        // An error while running is only logged.
        s.apply(.error("something"))
        XCTAssertEqual(s.phase, .running)
        XCTAssertEqual(s.log.last, "error: something")
    }

    func testAnErrorWhileStartingEndsTheStartWithItsReason() {
        let fresh = model()
        fresh.apply(.ready(python: "3.13.16"))
        XCTAssertEqual(fresh.phase, .starting)
        fresh.apply(.error("ValueError: The radio's txpower is 99: it has to be between 0 and 37"))
        XCTAssertEqual(fresh.phase, .idle)
        XCTAssertEqual(fresh.lastStartError, "The radio's txpower is 99: it has to be between 0 and 37", "plain words, no Python exception name")
        XCTAssertTrue(fresh.canStart)
    }

    func testStopThenStartInOneRun() {
        let s = model()
        started(s)
        XCTAssertFalse(s.canStart, "running")
        s.apply(.message(.init(id: "m1", incoming: false, peer: maya, text: "hi", at: Date(), delivery: .sending)))
        s.apply(.stopped)
        XCTAssertEqual(s.phase, .stopped)
        XCTAssertTrue(s.canStart, "Reticulum stays in the process: a new start attaches its interfaces again")
        XCTAssertEqual(s.address, "221b", "the same address")
        XCTAssertEqual(s.thread(with: maya).first?.failure, .interrupted, "what was on its way is marked, not left spinning")
        // The bridge refuses a restart: stopped again, with the reason.
        s.apply(.ready(python: "3.13.16"))
        s.apply(.error("ValueError: nope"))
        XCTAssertEqual(s.phase, .stopped)
        started(s)
        XCTAssertEqual(s.phase, .running)
        XCTAssertNil(s.lastStartError)
    }

    func testStartNeedsAnRNodeOrTheInternetLink() {
        // Reticulum ends the app on an RNode it refuses, so nothing reaches it without the checks.
        let s = model()
        XCTAssertTrue(s.useRNode)
        XCTAssertFalse(s.internetOn, "the internet link is off until the person turns it on")
        XCTAssertEqual(s.internetHost, "", "Wildcat ships no node addresses")
        s.start(link: nil)
        XCTAssertEqual(s.phase, .idle)
        XCTAssertEqual(s.lastStartError, "Connect an RNode, or turn on the internet link.")
    }

    func testTheInternetLinkAloneIsEnoughAndIsCheckedAndSaved() {
        let s = model()
        s.internetOn = true
        XCTAssertEqual(s.startPlan(nil).failureReason, Reticulum.InternetLinkProblem.noHost.line)
        s.internetHost = "node example"
        XCTAssertEqual(s.startPlan(nil).failureReason, Reticulum.InternetLinkProblem.badHost.line)
        s.internetHost = "Node.Example.org"
        s.internetPort = "70000"
        XCTAssertEqual(s.startPlan(nil).failureReason, Reticulum.InternetLinkProblem.badPort.line)
        s.internetPort = "4242"
        XCTAssertEqual(try? s.startPlan(nil).get(), Reticulum.StartPlan(radio: nil, internet: .init(host: "node.example.org", port: 4242)))
        // Kept for next time.
        let again = model()
        XCTAssertTrue(again.internetOn)
        XCTAssertEqual(again.internetHost, "Node.Example.org")
        XCTAssertEqual(again.internetPort, "4242")
        // Off again: back to needing an RNode.
        again.internetOn = false
        XCTAssertEqual(again.startPlan(nil).failureReason, "Connect an RNode, or turn on the internet link.")
    }

    func testEitherLinkOnlineIsEnoughToSend() {
        let s = model()
        started(s)
        s.apply(.interfaces([.init(name: "TCPInterface[Internet link/node.example.org:4242]", online: false)]))
        XCTAssertFalse(s.anyLinkOnline)
        s.apply(.interfaces([.init(name: "TCPInterface[Internet link/node.example.org:4242]", online: true)]))
        XCTAssertTrue(s.internetOnline)
        XCTAssertFalse(s.radioOnline)
        XCTAssertTrue(s.anyLinkOnline)
    }

    func testRadioSettingsAreThePersonsAndRemembered() {
        let s = model()
        XCTAssertNil(s.plannedSettings(nil), "nothing set anywhere: there is no built-in default to transmit on")
        let mine = Reticulum.RadioSettings(frequencyHz: 868_100_000, bandwidthHz: 250_000, spreadingFactor: 10, codingRate: 6, txPower: 14)
        s.lastSettings = mine
        let again = model()
        XCTAssertEqual(again.plannedSettings(nil)?.settings, mine)
        XCTAssertEqual(again.plannedSettings(nil)?.source, .lastUsed)
        XCTAssertEqual(mine.line, "868.1 MHz · 250 kHz · SF10 · CR 4/6 · 14 dBm")
        s.displayName = "MAYA"
        XCTAssertEqual(model().displayName, "MAYA", "the name is kept")
    }

    func testSendNeedsARunningStackAndA32DigitAddress() {
        let s = model()
        XCTAssertNil(s.send(to: maya, text: "hi"), "not running")
        started(s)
        XCTAssertNil(s.send(to: "abc", text: "hi"))
        XCTAssertNil(s.send(to: String(repeating: "z", count: 32), text: "hi"), "not hex")
        XCTAssertNil(s.send(to: maya, text: "  \n"))
        XCTAssertNotNil(s.send(to: "<" + maya.uppercased() + ">", text: "hi"), "brackets and case are fine")
    }

    // MARK: Safety: nothing reaches a screen, a notification or the save file unfiltered

    func testABlockedSenderIsDroppedBeforeAnythingSeesIt() {
        let safety = Safety(defaults: defaults)
        let s = model()
        s.safety = safety
        var notified: [String] = []
        s.notify = { m, _, _ in notified.append(m.id) }
        started(s)
        s.apply(.announce(.init(hash: sam, name: "SAM", hops: 1, at: Date())))
        s.apply(incoming("h1", from: sam, "first"))
        XCTAssertEqual(notified, ["h1"])
        safety.block(.reticulum(sam, name: "SAM"))
        XCTAssertTrue(s.conversations.isEmpty, "blocked: the conversation is gone from every list")
        XCTAssertTrue(s.heard.isEmpty)
        XCTAssertTrue(s.thread(with: sam).isEmpty)
        XCTAssertEqual(s.unread, 0)
        s.apply(incoming("h2", from: sam, "second"))
        XCTAssertEqual(notified, ["h1"], "no notification from a blocked sender")
        XCTAssertFalse(s.book.messages.contains { $0.id == "h2" }, "and it is never stored")
        // Blocking is by address: the same name on another address is someone else.
        s.apply(incoming("h3", from: maya, "hello"))
        XCTAssertEqual(s.conversations.map(\.peer), [maya])
        safety.unblock(.reticulum(sam, name: "SAM"))
        XCTAssertEqual(Set(s.conversations.map(\.peer)), [maya, sam])
    }

    func testTheWordFilterCoversTextNamesAndNotifications() throws {
        let word = try XCTUnwrap(WordFilter.words.first)
        let safety = Safety(defaults: defaults)
        let s = model()
        s.safety = safety
        var bodies: [String] = []
        var titles: [String] = []
        s.notify = { _, title, body in titles.append(title); bodies.append(body) }
        started(s)
        s.apply(.announce(.init(hash: sam, name: word, hops: 1, at: Date())))
        s.apply(incoming("h1", from: sam, "you \(word)"))
        let m = try XCTUnwrap(s.thread(with: sam).first)
        XCTAssertFalse(s.shown(m).contains(word))
        XCTAssertTrue(s.shown(m).contains(WordFilter.mask))
        XCTAssertFalse(s.title(for: sam).contains(word), "a stranger's announced name is filtered too")
        XCTAssertFalse(bodies.joined().contains(word))
        XCTAssertFalse(titles.joined().contains(word))
        // Your own words are yours.
        s.apply(.message(.init(id: "m1", incoming: false, peer: sam, text: "no, \(word)", at: Date(), delivery: .queued)))
        XCTAssertTrue(s.shown(try XCTUnwrap(s.thread(with: sam).last)).contains(word))
        safety.filterWords = false
        XCTAssertTrue(s.shown(m).contains(word))
    }

    func testUnverifiedIsMarkedAndABadSignatureIsDropped() {
        let s = model()
        var notified = 0
        s.notify = { _, _, _ in notified += 1 }
        started(s)
        s.apply(incoming("h1", from: maya, "who am I", trust: .unknownSender))
        XCTAssertEqual(s.thread(with: maya).first?.trust, .unknownSender)
        XCTAssertNotNil(s.thread(with: maya).first?.trust?.note)
        s.apply(incoming("h2", from: maya, "forged", trust: .badSignature))
        XCTAssertEqual(s.thread(with: maya).map(\.id), ["h1"])
        XCTAssertEqual(notified, 1)
    }

    func testOnesOwnAnnounceIsNotAPerson() {
        let s = model()
        s.apply(.started(.init(address: maya)))
        s.apply(.announce(.init(hash: maya, name: "me", hops: 0, at: Date())))
        XCTAssertTrue(s.heard.isEmpty)
    }

    // MARK: Saving

    func testConversationsAndPeopleSurviveARestart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reticulum-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = model(book: url)
        started(s)
        s.apply(.announce(.init(hash: maya, name: "MAYA", hops: 1, stampCost: 8, at: Date())))
        s.apply(.message(.init(id: "m1", incoming: false, peer: maya, text: "hi", at: Date(), delivery: .queued)))
        s.apply(.messageState(id: "m1", delivery: .sending, failure: nil, detail: nil))
        s.apply(incoming("h1", from: maya, "yo"))
        s.persist()
        let again = model(book: url)
        XCTAssertEqual(again.heard.first?.name, "MAYA")
        XCTAssertEqual(again.heard.first?.needsStamp, true)
        XCTAssertEqual(again.thread(with: maya).map(\.id), ["m1", "h1"])
        XCTAssertEqual(again.thread(with: maya).first?.delivery, .failed, "it was still sending when the app closed")
        XCTAssertEqual(again.thread(with: maya).first?.failure, .interrupted)
        XCTAssertEqual(again.unread, 1)
        // The identity key is never in the file.
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains("identity"))
        // An unreadable file is set aside, not overwritten, and the app starts clean.
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(model(book: url).conversations.isEmpty)
        let kept = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(url.lastPathComponent + ".bad-") }
        XCTAssertFalse(kept.isEmpty)
        for k in kept { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(k)) }
    }

    func testReticulumsOwnFolderIsLeftOutOfBackups() throws {
        let dir = ReticulumModel.storageDirectory()
        XCTAssertEqual(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true,
                       "ratchet keys and the transport identity stay on this phone")
        XCTAssertFalse(dir.path.contains("/Documents/"))
        XCTAssertFalse(try XCTUnwrap(ReticulumModel.defaultBookURL()).path.contains("/Documents/"), "not where the Files app looks")
    }

    func testIdentityKeyRoundTripsThroughTheKeychain() {
        let service = "com.thebench.wildcatgames.tests.reticulum.\(UUID().uuidString)"
        defer { ReticulumKeychain.deleteIdentity(service: service) }
        XCTAssertNil(ReticulumKeychain.loadIdentity(service: service))
        let key = Data((0..<64).map { UInt8($0) })
        XCTAssertTrue(ReticulumKeychain.saveIdentity(key, service: service))
        XCTAssertEqual(ReticulumKeychain.loadIdentity(service: service), key)
        let other = Data(repeating: 7, count: 64)
        XCTAssertTrue(ReticulumKeychain.saveIdentity(other, service: service), "saving again replaces")
        XCTAssertEqual(ReticulumKeychain.loadIdentity(service: service), other)
        XCTAssertFalse(ReticulumKeychain.saveIdentity(Data(repeating: 1, count: 32), service: service), "only 64-byte keys")
        XCTAssertTrue(ReticulumKeychain.deleteIdentity(service: service))
        XCTAssertNil(ReticulumKeychain.loadIdentity(service: service))
    }

    func testHex() {
        XCTAssertEqual(Data([0x00, 0xab, 0xff]).hexString, "00abff")
        XCTAssertEqual(Data(hexString: "00ABff"), Data([0x00, 0xab, 0xff]))
        XCTAssertNil(Data(hexString: "abc"))
        XCTAssertNil(Data(hexString: "zz"))
        XCTAssertEqual(Data(hexString: ""), Data())
    }

    func testTheBuildPutPythonInTheBundle() throws {
        // The test host is the app: install-python.sh ran for it.
        let paths = try XCTUnwrap(ReticulumRuntime.Paths.bundle())
        XCTAssertTrue(paths.installed, "stdlib, bridge and RNS in \(paths.home)")
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: paths.appPackages + "/LXMF/__init__.py"))
        XCTAssertTrue(fm.fileExists(atPath: paths.app + "/WildcatRNodeInterface.py"))
        XCTAssertFalse(fm.fileExists(atPath: paths.home + "/lib/python3.13/test"), "CPython's test suite is pruned")
        let frameworks = try fm.contentsOfDirectory(atPath: Bundle.main.bundlePath + "/Frameworks")
        XCTAssertTrue(frameworks.contains("Python.framework"))
        XCTAssertTrue(frameworks.contains { $0.hasPrefix("cryptography.hazmat.bindings._rust") }, "\(frameworks)")
    }
}
