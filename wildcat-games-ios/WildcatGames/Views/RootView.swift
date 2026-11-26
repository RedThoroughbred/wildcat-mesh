import SwiftUI
import UIKit
import WildcatRadioCore

/// The five tabs. Explore was one until 2.0; it is on Play and in the ≡ menu now.
enum AppTab: String, Hashable {
    case play, messages, mesh, meshcore, reticulum

    /// The tab of a radio network.
    init(_ network: MeshNetwork) { self = network == .meshtastic ? .mesh : .meshcore }
}

/// The selected tab, shared so the radio pill can jump to a network's tab.
@MainActor
@Observable
final class TabRouter {
    var tab = AppTab.play
    /// Bumps when something (an accepted hunt invite) wants the Fox Hunt screen open on Play.
    var huntRequest = 0
    /// Fox Hunt screens on screen right now.
    var huntScreensShown = 0

    /// Opens Fox Hunt on Play, unless a Fox Hunt screen is already showing (scanned from there).
    func showHunt() {
        tab = .play
        if huntScreensShown <= 0 { huntRequest += 1 }
    }

    /// Bumps when a Hunt game's invite was accepted: Play opens the game.
    var gameRequest = 0
    /// Hunt game screens on screen right now.
    var gameScreensShown = 0

    /// Opens the Hunt game on Play, unless its screen is already showing.
    func showGame() {
        tab = .play
        if gameScreensShown <= 0 { gameRequest += 1 }
    }

    /// Bumps when the radios sheet wants the RNode console (it has no tab of its own).
    var rnodeRequest = 0
    func showRNode() { rnodeRequest += 1 }

    /// Bumps when the radio pill wants the radios sheet.
    var radiosRequest = 0
    func showRadios() { radiosRequest += 1 }
}

/// The sheets RootView presents for the whole app, one at a time: the radios sheet
/// (from the pill) and the RNode console (from the radios sheet or a network tab).
enum RootSheet: String, Identifiable {
    case radios, rnode
    /// Reticulum (beta) opened by a launch argument (-ReticulumSpike, -ReticulumAutoTest).
    case reticulum
    var id: String { rawValue }
}

extension EnvironmentValues {
    /// The app's tab router (nil outside the tab view, e.g. in previews).
    @Entry var tabRouter: TabRouter? = nil
}

struct RootView: View {
    @Environment(HuntModel.self) private var hunt
    @Environment(WalkRecorder.self) private var walker
    @Environment(MessageStore.self) private var messages
    @Environment(DenStore.self) private var den
    @Environment(Radio.self) private var radio
    @Environment(InviteHandler.self) private var invites
    @Environment(MeshCoreStore.self) private var meshcoreStore
    @Environment(SnapshotWriter.self) private var snapshots
    @Environment(MeshCoreLink.self) private var meshcore
    @Environment(RNodeLink.self) private var rnodeLink
    @Environment(\.scenePhase) private var phase
    @Environment(ExploreModel.self) private var explore
    @Environment(PhoneReferee.self) private var referee
    @Environment(GamePlay.self) private var gamePlay
    @State private var router = TabRouter()
    @State private var showGallery = false
    @State private var rootSheet: RootSheet?
    /// The console was asked for while the radios sheet was up: open it once that sheet is gone.
    @State private var consoleAfterRadios = false
    /// Location is running for the practice MeshCore node.
    @State private var followingPractice = false

    var body: some View {
        @Bindable var invites = invites
        @Bindable var router = router
        let tab = router.tab
        TabView(selection: $router.tab) {
            PlayView()
                .tabItem { Label("Play", systemImage: "gamecontroller") }
                .tag(AppTab.play)
            MessagesView()
                .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right") }
                .badge(messages.totalUnread)
                .tag(AppTab.messages)
            RadioView()
                .tabItem { Label("Meshtastic", systemImage: MeshNetwork.meshtastic.symbol) }
                .tag(AppTab.mesh)
            NavigationStack { MeshCoreView() }
                .tabItem { Label("MeshCore", systemImage: MeshNetwork.meshcore.symbol) }
                .badge(meshcoreStore.totalUnread)
                .tag(AppTab.meshcore)
            NavigationStack { ReticulumView() }
                .tabItem { Label("Reticulum", systemImage: ReticulumStyle.symbol) }
                .badge(ReticulumModel.shared.unread)
                .tag(AppTab.reticulum)
        }
        .environment(\.tabRouter, router)
        .sheet(item: $invites.pending) { invite in
            // Joined: straight to the hunt screen, waiting for the host.
            InviteSheet(invite: invite) { router.showHunt() }
        }
        .sheet(item: $invites.pendingGame) { invite in
            // Joined a Hunt game: straight to its board.
            GameInviteSheet(invite: invite) { router.showGame() }
        }
        // The radios sheet (from the pill) and the RNode console (from that sheet, or a network
        // tab's Manage), both presented here so neither hangs off a toolbar item (which can
        // vanish with its sheet). Radios sheet → console is dismiss, then present in onDismiss:
        // swapping the item under a live sheet doesn't reliably show the new one.
        .onChange(of: router.radiosRequest) { _, _ in rootSheet = .radios }
        .onChange(of: router.rnodeRequest) { _, _ in
            if rootSheet == .radios {
                consoleAfterRadios = true
                rootSheet = nil
            } else {
                rootSheet = .rnode
            }
        }
        .sheet(item: $rootSheet, onDismiss: {
            if consoleAfterRadios {
                consoleAfterRadios = false
                rootSheet = .rnode
            }
        }) { which in
            // These sheets attach outside `.environment(\.tabRouter)` above, so pass it on:
            // the radios sheet's RNode row asks the router for the console.
            Group {
                switch which {
                case .radios:
                    RadiosSheet()
                case .rnode:
                    NavigationStack { RNodeView() }
                        .presentationBackground(Theme.bg)
                case .reticulum:
                    NavigationStack { ReticulumView() }
                        .presentationBackground(Theme.bg)
                }
            }
            .environment(\.tabRouter, router)
        }
        .onAppear { LaunchTiming.mark("first screen") }
        #if DEBUG
        // Developer-only: -DesignGallery opens the design-system gallery; -Tab mesh picks a tab;
        // -Practice starts both practice radios (for screenshots without hardware).
        .sheet(isPresented: $showGallery) { NavigationStack { DesignGalleryView() } }
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-DesignGallery") { showGallery = true }
            if let t = UserDefaults.standard.string(forKey: "Tab").flatMap(AppTab.init(rawValue:)) { router.tab = t }
            if args.contains("-Practice") {
                radio.startPractice()
                if !meshcore.state.isReady { PracticeMode.startMeshCore(meshcore) }
            }
            // -RNodeAutoTest drives the RNode console from the Mac (devicectl --console shows its log).
            if args.contains("-RNodeAutoTest") { RNodeAutoTest.shared.start(rnodeLink) }
            // The Reticulum spike: -ReticulumSpike opens its screen; -ReticulumAutoTest also drives it
            // (tools/reticulum/sim-test.sh).
            if args.contains("-ReticulumSpike") || args.contains("-ReticulumAutoTest") { router.tab = .reticulum }
            if args.contains("-ReticulumAutoTest") { ReticulumAutoTest.shared.start(link: rnodeLink) }
            // -ReticulumSample [running|off|stopped|chat|chat-failed]: pretend people and messages for screenshots.
            if let i = args.firstIndex(of: "-ReticulumSample") {
                ReticulumModel.shared.loadSample(state: i + 1 < args.count ? args[i + 1] : nil)
                // With -Tab the sample only fills the lists (Messages with all three networks).
                if UserDefaults.standard.string(forKey: "Tab") == nil { router.tab = .reticulum }
            }
        }
        #endif
        // The selected tab (and that tab's controls) take its network's colour; elsewhere neutral white.
        .tint(tab == .mesh ? Theme.meshtastic : tab == .meshcore ? Theme.meshcore : Theme.accent)
        // Learn the hunt channel from any node that has it, for one-tap foxes.
        .onChange(of: radio.isReady, initial: true) { _, ready in if ready { QuickSetup.remember(radio.session) } }
        // Keep the last real node's name, channels and heard list for the disconnected Meshtastic tab.
        .onChange(of: cacheSignature) { _, _ in saveMeshtasticCache() }
        // Ask about notifications once a real node connects (messages can then arrive), not at launch.
        .onChange(of: (radio.source == .bluetooth && radio.isReady) || (meshcore.state.isReady && !meshcore.isDemo)) { _, connected in
            if connected { MessageStore.requestNotifications() }
        }
        // Screen stays on in the field while a hunt is active.
        .onChange(of: phase, initial: true) { _, p in
            messages.isForeground = (p == .active)
            meshcoreStore.isForeground = (p == .active)
            ReticulumModel.shared.isForeground = (p == .active)
            if p != .active { messages.save(); meshcoreStore.save(); snapshots.write(); saveMeshtasticCache(); referee.saveNow(); gamePlay.saveNow(); ReticulumModel.shared.persist() }
        }
        .onChange(of: hunt.stage.isActive || gamePlay.round?.stage == .live || (walker.isWalking && walker.walk?.drive != true), initial: true) { _, active in
            UIApplication.shared.isIdleTimerDisabled = active
        }
        // Practising MeshCore: follow the phone so the practice fox gets warmer as you walk.
        // Only with location already allowed (begin(asking: false) never asks).
        .onChange(of: meshcore.isDemo, initial: true) { _, on in
            guard on != followingPractice else { return }
            followingPractice = on
            if on { explore.begin(asking: false) } else { explore.end() }
        }
        // An App Store rating, once per version, after a delivered message or a found fox.
        .reviewPrompt()
    }

    /// Changes when the connected node's lists change (not on every packet).
    private var cacheSignature: String {
        guard radio.source == .bluetooth, radio.isReady else { return "" }
        let s = radio.session
        return "\(s.myNode?.raw ?? 0)-\(s.nodes.count)-\(s.channels.count)-\(s.firmware ?? "")"
    }

    /// Saves the connected (real) node for later.
    private func saveMeshtasticCache() {
        guard radio.source == .bluetooth, radio.isReady, let cache = MeshtasticCache(session: radio.session) else { return }
        cache.save()
    }
}

// MARK: - Radio pill

/// All three radios at a glance, top left on every tab: an LED in each network's
/// colour (grey when that radio isn't connected) and a short distinguishing name.
/// The LED blips when that radio hears a packet. Tap for every radio's status,
/// with a way to each tab (the RNode's console).
struct RadioPill: View {
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore
    @Environment(RNodeLink.self) private var rnode
    @Environment(PacketFeed.self) private var feed
    @Environment(\.tabRouter) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Previews have no router; the pill then shows the sheet itself.
    @State private var showRadios = false

    /// What the three names may take between them: the pill has to leave room for the
    /// title-bar buttons on a 393-point phone, and past that the bar drops the whole item.
    /// Two names used to get 92 points each; three share this.
    static let nameBudget: CGFloat = 164

    var body: some View {
        let _ = dynamicTypeSize
        let mt = Self.sample(RadioStatus.meshtastic(radio), as: "Practice Handheld")
        let mc = RadioStatus.meshcore(meshcore)
        let rn = Self.sample(RadioStatus.rnode(rnode), as: "RNode 4FDD")
        let statuses = [mt, mc, rn]
        let labels = Self.pillLabels(for: statuses)
        let measured = labels.map { Self.measuredWidth($0) }
        let widths = Self.shareWidths(measured, budget: Self.nameBudget)
        Button {
            if let router { router.showRadios() } else { showRadios = true }
        } label: {
            HStack(spacing: 8) {
                segment(labels[0], width: widths[0], color: MeshNetwork.meshtastic.color, on: mt.connected,
                        pulse: feed.events.first(where: { $0.network == .meshtastic })?.id,
                        truncation: Self.truncationMode(at: 0, labels: labels, statuses: statuses, widths: widths, measured: measured))
                divider
                segment(labels[1], width: widths[1], color: MeshNetwork.meshcore.color, on: mc.connected,
                        pulse: feed.events.first(where: { $0.network == .meshcore })?.id,
                        truncation: Self.truncationMode(at: 1, labels: labels, statuses: statuses, widths: widths, measured: measured))
                divider
                segment(labels[2], width: widths[2], color: RNodeStyle.color, on: rn.connected,
                        pulse: rnode.session.lastPacketAt,
                        truncation: Self.truncationMode(at: 2, labels: labels, statuses: statuses, widths: widths, measured: measured))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Theme.surface1, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.rowPress)
        .accessibilityLabel("Radios: \(mt.spoken). \(mc.spoken). \(rn.spoken).")
        .accessibilityHint("Shows all three radios")
        .sheet(isPresented: $showRadios) { RadiosSheet() }
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairlineStrong).frame(width: 1, height: 12)
    }

    /// A text here is fixed-size: the title bar proposes the leading item very little width
    /// and a flexible text would shrink to nothing. So each gets a width from `shareWidths`
    /// and truncates with an ellipsis past it.
    private func segment(_ name: String, width: CGFloat, color: Color, on: Bool, pulse: AnyHashable?,
                         truncation: Text.TruncationMode = .tail) -> some View {
        HStack(spacing: 5) {
            BlipLED(color: color, on: on, pulse: pulse)
            Text(name)
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(on ? Theme.textPrimary : Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(truncation)
                .frame(maxWidth: width, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Developer-only: -PillSample (with -Practice) draws the pill as with three radios connected,
    /// for screenshots: the simulator has no RNode. Nothing else believes it.
    private static func sample(_ status: RadioStatus, as name: String) -> RadioStatus {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PillSample") {
            return RadioStatus(network: status.network, connected: true, name: name, state: status.state, heard: status.heard)
        }
        #endif
        return status
    }

    /// Labels for the three pill segments, shortened only as much as needed to fit
    /// `budget` while keeping every connected radio distinct:
    /// 1. Disconnected slots start compact ("MT", "MC", "RNode") so connected names get room.
    /// 2. If tight, drop a redundant network prefix ("RNode 4FDD" → "4FDD").
    /// 3. If still tight, drop shared leading words among connected radios ("Wildcat Nag",
    ///    "Wildcat Bag" → "Nag", "Bag"), then shared trailing words ("Roof Node", "Bag Node").
    /// 4. If still tight, compact disconnected "RNode" to "RN".
    static func pillLabels(for statuses: [RadioStatus], budget: CGFloat = RadioPill.nameBudget,
                           measure: ((String) -> CGFloat)? = nil) -> [String] {
        var labels = statuses.map { s in
            s.connected ? s.pillName : (s.network?.short ?? RNodeStyle.name)
        }
        func totalWidth() -> CGFloat {
            labels.reduce(0) { $0 + (measure?($1) ?? measuredWidth($1)) }
        }
        guard totalWidth() > budget else { return labels }

        for i in statuses.indices where statuses[i].connected {
            labels[i] = trimKindPrefix(labels[i], kind: statuses[i].kindName)
        }
        guard totalWidth() > budget else { return labels }

        let connected = statuses.indices.filter { statuses[$0].connected }

        while totalWidth() > budget {
            var groups: [String: [(index: Int, rest: String)]] = [:]
            for i in connected {
                let (token, rest) = splitFirstToken(labels[i])
                guard !token.isEmpty else { continue }
                groups[token.lowercased(), default: []].append((i, rest))
            }
            var changed = false
            for members in groups.values where members.count >= 2 {
                // Only when every radio sharing the word keeps something: "Practice" and
                // "Practice Node" stay as they are, or the pill would read "Practice · Node".
                guard members.allSatisfy({ !$0.rest.isEmpty }) else { continue }
                let strippable = members
                for m in strippable {
                    labels[m.index] = m.rest
                    changed = true
                }
            }
            if !changed { break }
        }
        guard totalWidth() > budget else { return labels }

        while totalWidth() > budget {
            var groups: [String: [(index: Int, rest: String)]] = [:]
            for i in connected {
                let (rest, token) = splitLastToken(labels[i])
                guard !token.isEmpty else { continue }
                groups[token.lowercased(), default: []].append((i, rest))
            }
            var changed = false
            for members in groups.values where members.count >= 2 {
                // Only when every radio sharing the word keeps something: "Practice" and
                // "Practice Node" stay as they are, or the pill would read "Practice · Node".
                guard members.allSatisfy({ !$0.rest.isEmpty }) else { continue }
                let strippable = members
                for m in strippable {
                    labels[m.index] = m.rest
                    changed = true
                }
            }
            if !changed { break }
        }
        guard totalWidth() > budget else { return labels }

        for i in statuses.indices where !statuses[i].connected && statuses[i].network == nil {
            labels[i] = "RN"
        }
        return labels
    }

    /// Falls back to middle truncation when two connected labels still share a leading
    /// prefix and one overflows its share (e.g. "wildcatnode1" vs "wildcatnode2").
    static func truncationMode(at index: Int, labels: [String], statuses: [RadioStatus],
                               widths: [CGFloat], measured: [CGFloat]) -> Text.TruncationMode {
        guard index < statuses.count, index < labels.count, index < widths.count, index < measured.count,
              statuses[index].connected, measured[index] > widths[index] else { return .tail }
        let mine = labels[index].lowercased()
        guard mine.count >= 4 else { return .tail }
        let lead = mine.prefix(4)
        let collides = statuses.indices.contains { other in
            other != index && other < labels.count && statuses[other].connected
                && labels[other].lowercased().hasPrefix(lead)
        }
        return collides ? .middle : .tail
    }

    /// Rendered width of a pill label in the pill's footnote medium font, with 2 pt cushion.
    static func measuredWidth(_ text: String) -> CGFloat {
        let size = UIFont.preferredFont(forTextStyle: .footnote).pointSize
        let font = UIFont.systemFont(ofSize: size, weight: .medium)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
    }

    /// Shares `budget` points out among `wanted` widths, shortest first, so short
    /// names leave their spare room to longer ones.
    static func shareWidths(_ wanted: [CGFloat], budget: CGFloat) -> [CGFloat] {
        var widths = [CGFloat](repeating: 0, count: wanted.count)
        var left = budget
        var remaining = wanted.indices.sorted { wanted[$0] < wanted[$1] }
        while let i = remaining.first {
            let share = left / CGFloat(remaining.count)
            widths[i] = min(wanted[i], share)
            left -= widths[i]
            remaining.removeFirst()
        }
        return widths
    }

    /// Shares `budget` points out among the names: each takes what it needs (about 7 points
    /// a character in the pill's footnote) up to an equal share of what's left, shortest
    /// first, so "RNode" leaves its spare room to "Wildcat Nag" and "Wildcat Bag".
    static func nameWidths(_ names: [String], budget: CGFloat) -> [CGFloat] {
        shareWidths(names.map { CGFloat($0.count) * 7 + 2 }, budget: budget)
    }

    private static func isSeparator(_ c: Character) -> Bool {
        c.isWhitespace || c == "-" || c == "_" || c == "." || c == "/" || c == ":" || c == "·"
    }

    /// Drops a leading network/modem name ("RNode 4FDD" → "4FDD", "MeshCore Bag" → "Bag")
    /// when followed by a separator and something left to show.
    private static func trimKindPrefix(_ name: String, kind: String) -> String {
        guard let range = name.range(of: kind, options: [.caseInsensitive, .anchored]) else { return name }
        let tail = name[range.upperBound...]
        guard let first = tail.first, isSeparator(first) else { return name }
        let rest = tail.drop(while: { isSeparator($0) })
        return rest.isEmpty ? name : String(rest)
    }

    /// Splits the leading token off `name` at a separator ("Wildcat Nag", "Wildcat-Nag")
    /// or a CamelCase transition ("WildcatNag", prefix ≥ 2 chars).
    private static func splitFirstToken(_ name: String) -> (token: String, rest: String) {
        guard !name.isEmpty else { return ("", "") }
        var seenContent = false
        var prev: Character?
        var count = 0
        for i in name.indices {
            let c = name[i]
            if isSeparator(c) {
                if seenContent {
                    let rest = name[i...].drop(while: { isSeparator($0) })
                    return (String(name[..<i]), String(rest))
                }
            } else {
                if seenContent, count >= 2, let prev, prev.isLowercase, c.isUppercase {
                    return (String(name[..<i]), String(name[i...]))
                }
                seenContent = true
                count += 1
            }
            prev = c
        }
        return (name, "")
    }

    /// Splits the trailing token off `name` at a separator ("Roof Node") or a CamelCase
    /// transition ("RoofNode", rest ≥ 2 chars).
    private static func splitLastToken(_ name: String) -> (rest: String, token: String) {
        guard !name.isEmpty else { return ("", "") }
        var i = name.endIndex
        var seenContent = false
        var next: Character?
        while i > name.startIndex {
            let cur = name.index(before: i)
            let c = name[cur]
            if isSeparator(c) {
                if seenContent {
                    var end = cur
                    while end > name.startIndex, isSeparator(name[name.index(before: end)]) {
                        end = name.index(before: end)
                    }
                    return (String(name[..<end]), String(name[i...]))
                }
            } else {
                if seenContent, let next, c.isLowercase, next.isUppercase {
                    let restSlice = name[..<i]
                    if restSlice.count >= 2 {
                        return (String(restSlice), String(name[i...]))
                    }
                }
                seenContent = true
            }
            next = c
            i = cur
        }
        return ("", name)
    }
}

/// A status LED whose ring leaps out when `pulse` changes (a packet was heard).
private struct BlipLED: View {
    let color: Color
    let on: Bool
    let pulse: AnyHashable?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(opacity), lineWidth: 1.2).frame(width: 6, height: 6).scaleEffect(scale)
            StatusLED(color: color, on: on, size: 6)
        }
        .onChange(of: pulse) { _, _ in
            guard on else { return }
            if reduceMotion {
                opacity = 0.9
                withAnimation(Theme.Motion.fade.delay(0.15)) { opacity = 0 }
                return
            }
            scale = 1
            opacity = 0.95
            withAnimation(.easeOut(duration: 0.7)) {
                scale = 3.2
                opacity = 0
            }
        }
    }
}

/// What the pill and its sheet say about one radio. `network` is nil for the RNode,
/// which is a Reticulum modem with a console rather than a mesh with a tab.
struct RadioStatus {
    let network: MeshNetwork?
    let connected: Bool
    /// The node's name, or what the link is doing.
    let name: String
    /// "Connected · Bluetooth", "Practice on this phone", "Not connected".
    let state: String
    let heard: Int?

    /// "Meshtastic", "MeshCore" or "RNode".
    var kindName: String { network?.name ?? RNodeStyle.name }
    /// Short enough for the pill: the node's name when connected, else the kind. A name
    /// that starts with an emoji ("🕸️Wildcat Nag") loses it: the pill has no room.
    var pillName: String {
        guard connected else { return kindName }
        let bare = name.drop(while: { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
        return bare.isEmpty ? name : bare
    }
    var spoken: String { "\(kindName) \(connected ? name : "not connected")" }

    @MainActor static func rnode(_ link: RNodeLink) -> RadioStatus {
        if case .ready(let n) = link.state {
            return RadioStatus(network: nil, connected: true, name: n, state: "Connected · Bluetooth",
                               heard: link.session.packetsHeard > 0 ? link.session.packetsHeard : nil)
        }
        let state: String
        switch link.state {
        case .scanning: state = "Scanning…"
        case .connecting(let n), .starting(let n): state = "Connecting \(n)…"
        case .failed: state = "Connection failed"
        case .poweredOff: state = "Bluetooth off"
        case .unauthorized: state = "Bluetooth not allowed"
        default: state = "Not connected"
        }
        return RadioStatus(network: nil, connected: false, name: RNodeStyle.name, state: state, heard: nil)
    }

    @MainActor static func meshtastic(_ radio: Radio) -> RadioStatus {
        let s = radio.session
        let me = s.myNode.flatMap { s.nodes[$0] }
        switch radio.source {
        case .practice:
            return RadioStatus(network: .meshtastic, connected: radio.isReady, name: "Practice",
                               state: "Practice mesh on this phone", heard: max(0, s.nodes.count - 1))
        case .bluetooth where radio.isReady:
            return RadioStatus(network: .meshtastic, connected: true, name: me?.longName ?? me?.shortName ?? radio.statusText,
                               state: "Connected · Bluetooth", heard: max(0, s.nodes.count - 1))
        default:
            return RadioStatus(network: .meshtastic, connected: false, name: radio.statusText,
                               state: radio.source == .none ? "Not connected" : radio.statusText, heard: nil)
        }
    }

    @MainActor static func meshcore(_ link: MeshCoreLink) -> RadioStatus {
        if link.state.isReady {
            return RadioStatus(network: .meshcore, connected: true, name: link.session.me?.name ?? "MeshCore",
                               state: link.isDemo ? "Practice node on this phone" : "Connected · Bluetooth",
                               heard: link.session.contacts.count)
        }
        let state: String
        switch link.state {
        case .scanning: state = "Scanning…"
        case .connecting(let n), .syncing(let n): state = "Connecting \(n)…"
        case .failed: state = "Connection failed"
        case .poweredOff: state = "Bluetooth off"
        case .unauthorized: state = "Bluetooth not allowed"
        default: state = "Not connected"
        }
        return RadioStatus(network: .meshcore, connected: false, name: "MeshCore", state: state, heard: nil)
    }
}

/// Both radios, from the pill: which is up, what it hears, and a way to its tab. Plus the
/// RNode (Reticulum modem), which has a console instead of a tab.
private struct RadiosSheet: View {
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore
    @Environment(RNodeLink.self) private var rnode
    @Environment(\.tabRouter) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ModuleHeader(nil, "Your radios")
            VStack(spacing: 0) {
                row(RadioStatus.meshtastic(radio))
                PanelDivider()
                row(RadioStatus.meshcore(meshcore))
                PanelDivider()
                rnodeRow
            }
            .instrumentPanel()
            Text("Each network needs its own node. Tap one to open it. The RNode is a Reticulum modem: its messages are on the Reticulum tab.")
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.edge)
        .padding(.top, 8)
        .presentationDetents([.height(330)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.bg)
    }

    private func row(_ s: RadioStatus) -> some View {
        let network = s.network ?? .meshtastic
        return Button {
            dismiss()
            router?.tab = AppTab(network)
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: network.symbol, tint: s.connected ? network.color : nil, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(s.connected ? s.name : network.name)
                            .font(Theme.Fonts.heading)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        NetworkTag(network)
                    }
                    HStack(spacing: 6) {
                        StatusLED(color: Theme.ok, on: s.connected, size: 6)
                        Text(s.state + (s.heard.map { " · hears \($0)" } ?? ""))
                            .font(Theme.Fonts.detail)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Chevron()
            }
            .padding(.horizontal, Theme.Space.rowH)
            .padding(.vertical, Theme.Space.rowV)
            .contentShape(Rectangle())
        }
        .buttonStyle(.rowPress)
        .accessibilityHint("Opens the \(network.name) tab")
    }

    private var rnodeRow: some View {
        let connected = rnode.state.isReady
        let name: String = { if case .ready(let n) = rnode.state { return n } else { return RNodeStyle.name } }()
        let state: String = {
            switch rnode.state {
            case .ready: return "Connected · Bluetooth"
            case .connecting, .starting: return "Connecting…"
            case .scanning: return "Scanning…"
            case .failed: return "Connection failed"
            case .poweredOff: return "Bluetooth off"
            case .unauthorized: return "Bluetooth not allowed"
            case .idle: return "Not connected"
            }
        }()
        return Button {
            if let router { router.showRNode() } else { dismiss() }
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: RNodeStyle.symbol, tint: connected ? RNodeStyle.color : nil, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(name).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Tag("Reticulum", color: RNodeStyle.color)
                    }
                    HStack(spacing: 6) {
                        StatusLED(color: Theme.ok, on: connected, size: 6)
                        Text(state).font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Chevron()
            }
            .padding(.horizontal, Theme.Space.rowH)
            .padding(.vertical, Theme.Space.rowV)
            .contentShape(Rectangle())
        }
        .buttonStyle(.rowPress)
        .accessibilityLabel("RNode \(connected ? name : "not connected")")
        .accessibilityHint("Opens the RNode console")
    }
}
