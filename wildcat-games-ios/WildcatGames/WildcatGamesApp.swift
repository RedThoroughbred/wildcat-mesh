import SwiftUI
import UserNotifications
import WildcatRadioCore

@main
struct WildcatGamesApp: App {
    @State private var radio: Radio
    @State private var hunt: HuntModel
    @State private var heading = Heading()
    @State private var den: DenStore
    @State private var walker: WalkRecorder
    @State private var games: GamesStore
    @State private var explore: ExploreModel
    @State private var messages: MessageStore
    @State private var admin: NodeAdmin
    @State private var traceroutes: Traceroutes
    @State private var solo: SoloHunt
    @State private var gifts: GiftStore
    @State private var activity: RadioActivity
    @State private var referee: PhoneReferee
    @State private var gamePlay: GamePlay
    @State private var invites: InviteHandler
    @State private var meshcore: MeshCoreLink
    /// The RNode (Reticulum modem) console's link; Bluetooth is only touched from the console.
    @State private var rnode: RNodeLink
    @State private var bridge: MeshBridge
    @State private var meshcoreStore: MeshCoreStore
    @State private var meshcoreHunt: MeshCoreHunt
    @State private var snapshots: SnapshotWriter
    @State private var myMesh: MyMeshStore
    @State private var safety: Safety
    @State private var packetFeed: PacketFeed
    /// The firmware list, fetched only when the user taps Check for updates.
    @State private var firmware = FirmwareCheck()

    init() {
        LaunchTiming.mark("app init")
        // Before any screen can ask: lets notices tell a choice made now from an earlier one.
        PermissionHistory.record()
        let radio = Radio()
        _radio = State(initialValue: radio)
        let hunt = HuntModel(radio: radio)
        _hunt = State(initialValue: hunt)
        let messages = MessageStore(radio: radio)
        _messages = State(initialValue: messages)
        let admin = NodeAdmin(radio: radio)
        _admin = State(initialValue: admin)
        _traceroutes = State(initialValue: Traceroutes(radio: radio))
        _solo = State(initialValue: SoloHunt(radio: radio))
        let meshcore = MeshCoreLink()
        _gifts = State(initialValue: GiftStore(radio: radio, meshcore: meshcore))
        _activity = State(initialValue: RadioActivity(radio: radio))
        _packetFeed = State(initialValue: PacketFeed(radio: radio, meshcore: meshcore))
        let referee = PhoneReferee(radio: radio)
        _referee = State(initialValue: referee)
        _meshcore = State(initialValue: meshcore)
        let meshcoreStore = MeshCoreStore(link: meshcore)
        _meshcoreStore = State(initialValue: meshcoreStore)
        _meshcoreHunt = State(initialValue: MeshCoreHunt(link: meshcore))
        let myMesh = MyMeshStore()
        myMesh.attach(radio: radio)
        myMesh.attach(meshcore: meshcore)
        _myMesh = State(initialValue: myMesh)
        meshcore.onDiagnostic = { [weak hunt] in hunt?.note($0) }
        let rnode = RNodeLink()
        rnode.onDiagnostic = { [weak hunt] in hunt?.note($0) }
        _rnode = State(initialValue: rnode)
        let keepRaw = UserDefaults.standard.bool(forKey: MessageStore.keepRawKey)
        messages.keepsRawPackets = keepRaw
        meshcore.keepsRawPackets = keepRaw
        // Bring back the nodes used last time. Only after a connection, so a
        // first launch never touches Bluetooth (no permission prompt).
        if UserDefaults.standard.bool(forKey: "meshlink.autoReconnect") { radio.useBluetooth() }
        if meshcore.wantsReconnect { meshcore.reconnectLast() }
        // The RNode too: a paired phone reconnects without a PIN. (Disconnect in its console
        // turns this off until the next connect, so it stays free for rnsd on a computer.)
        if rnode.wantsReconnect { rnode.reconnectLast() }
        let bridge = MeshBridge(radio: radio, meshcore: meshcore, messages: messages)
        bridge.onNote = { [weak hunt] in hunt?.note($0) }
        _bridge = State(initialValue: bridge)
        // Blocks and the word filter reach every place messages show up or cross.
        let safety = Safety(radio: radio, admin: admin)
        _safety = State(initialValue: safety)
        messages.safety = safety
        meshcoreStore.safety = safety
        bridge.safety = safety
        ReticulumModel.shared.safety = safety
        // A MeshCore block by name also covers that contact's direct messages and room posts.
        safety.meshcoreName = { [weak meshcoreStore] p in meshcoreStore?.source.contact(prefix: p)?.name }
        _snapshots = State(initialValue: SnapshotWriter(radio: radio, meshcore: meshcore, meshcoreStore: meshcoreStore,
                                                        messages: messages, bridge: bridge))
        // Host and hunt on one phone: the hunter's commands and the referee's replies loop back locally.
        hunt.localReferee = { [weak referee] in referee?.acceptLocal($0) ?? false }
        referee.onLocalReply = { [weak hunt] in hunt?.receive(localReply: $0) }
        Chrome.apply()
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        let den = DenStore()
        _den = State(initialValue: den)
        // Hunt for 2–3 friends (Small Play 2): its pieces' lines are the game's, not the single hunt's.
        let gamePlay = GamePlay(radio: radio)
        _gamePlay = State(initialValue: gamePlay)
        _invites = State(initialValue: InviteHandler(radio: radio, hunt: hunt, admin: admin, games: gamePlay))
        let walker = WalkRecorder(radio: radio, den: den)
        _walker = State(initialValue: walker)
        _games = State(initialValue: GamesStore(den: den))
        let explore = ExploreModel(radio: radio, den: den, walker: walker)
        _explore = State(initialValue: explore)
        radio.practiceCenter = { [weak explore] in explore?.lastKnown }
        // Practice MeshCore too: placed around the phone, and following it as you walk.
        PracticeMode.location = { [weak explore] in explore?.lastKnown }
        explore.onMove = { [weak meshcore] p in if let meshcore { PracticeMode.walked(to: p, meshcore) } }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(radio)
                .environment(hunt)
                .environment(heading)
                .environment(den)
                .environment(walker)
                .environment(games)
                .environment(explore)
                .environment(messages)
                .environment(admin)
                .environment(traceroutes)
                .environment(solo)
                .environment(gifts)
                .environment(activity)
                .environment(referee)
                .environment(gamePlay)
                .environment(invites)
                .environment(meshcore)
                .environment(rnode)
                .environment(bridge)
                .environment(meshcoreStore)
                .environment(meshcoreHunt)
                .environment(snapshots)
                .environment(myMesh)
                .environment(safety)
                .environment(packetFeed)
                .environment(firmware)
                .onOpenURL { url in
                    if !invites.open(url.absoluteString) { gifts.importLink(url.absoluteString) }
                }
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .toggleStyle(FieldToggleStyle())
        }
    }
}
