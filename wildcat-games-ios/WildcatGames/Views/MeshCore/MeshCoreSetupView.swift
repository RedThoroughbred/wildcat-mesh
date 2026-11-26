import SwiftUI
import WildcatRadioCore

/// "Set up this node" for MeshCore, i.e. create the network: the radio preset your
/// local mesh uses, a name, whether adverts carry your position, a first private
/// channel, and a first advert so nearby nodes add you. Reviewed, then applied
/// step by step with each step checked.
struct MeshCoreSetupView: View {
    enum Page: Int, CaseIterable { case radio, name, position, channel, review, apply }
    enum RadioChoice: Hashable { case keep, preset(String) }

    @Environment(MeshCoreLink.self) private var link
    @Environment(\.dismiss) private var dismiss
    @State private var page = Page.radio
    @State private var loaded = false
    @State private var radio = RadioChoice.keep
    @State private var showAll = false
    @State private var name = ""
    @State private var share = false
    @State private var makeChannel = true
    @State private var channelName = ""
    @State private var advert = true
    @State private var apply = MeshCoreApply()
    @State private var slot = MeshCoreSlotBox()
    @State private var locating = false

    /// The phone's region ("US"), for suggesting a preset.
    var regionCode: String? = Locale.current.region?.identifier

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                if let me = link.session.me {
                    steps
                    switch page {
                    case .radio: radioPage(me)
                    case .name: namePage(me)
                    case .position: positionPage(me)
                    case .channel: channelPage
                    case .review: reviewPage(me)
                    case .apply: applyPage
                    }
                } else {
                    EmptyState(symbol: MeshNetwork.meshcore.symbol, title: "No MeshCore node",
                               text: "Connect a MeshCore companion node first, then set it up here.")
                        .panel(.inset)
                }
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
            .animation(Theme.Motion.settle, value: page)
        }
        .screen()
        .safeAreaInset(edge: .bottom) { if link.session.me != nil { footer } }
        .navigationTitle("Set up this node")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(apply.isWorking)
        .onAppear(perform: load)
    }

    // MARK: Pages

    private var steps: some View {
        let titles = ["Radio", "Name", "Position", "Channel", "Review"]
        let at = min(page.rawValue, titles.count - 1)
        return HStack(spacing: 10) {
            SegmentMeter(lit: page == .apply ? titles.count : at + 1, of: titles.count, tint: Theme.meshcore, size: .regular)
            Text(page == .apply ? applyWord : "Step \(at + 1) of \(titles.count) · \(titles[at])")
                .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func radioPage(_ me: MeshCore.SelfInfo) -> some View {
        let suggested = MeshCorePresets.suggested(regionCode: regionCode)
        let current = MeshCorePresets.match(me, regionCode: regionCode)
        ExplainerPanel("Which mesh are you joining?",
                       text: "Every MeshCore node that talks to yours must use the same frequency, bandwidth, spreading factor and coding rate. Pick the preset your local mesh uses: these are MeshCore's own community presets.")
        if !suggested.isEmpty {
            ModuleHeader(1, "Suggested", detail: regionName)
            choices(suggested, current: current)
        } else if regionName != nil {
            Notice(text: "MeshCore has no preset for \(regionName ?? "your region"). Pick the one your local mesh uses, or keep this node's settings.",
                   symbol: "globe")
        }
        // On a preset already, its row says "Now"; otherwise offer to keep the custom settings.
        if current == nil {
            ModuleHeader(suggested.isEmpty ? 1 : 2, "This node now")
            VStack(spacing: 0) {
                choiceRow(.keep, title: "Keep this node's settings",
                          subtitle: MeshCorePreset(title: "", frequency: me.frequency, bandwidth: me.bandwidth,
                                                   spreadingFactor: me.spreadingFactor, codingRate: me.codingRate).summary,
                          tag: "Custom")
            }
            .panel(.inset)
        }
        // Right under the choices people usually make, so it's seen without scrolling.
        radioNotices(me)
        ModuleHeader((suggested.isEmpty ? 1 : 2) + (current == nil ? 1 : 0), "All MeshCore presets", action: showAll ? "Hide" : "Show",
                     symbol: showAll ? "chevron.up" : "chevron.down") { showAll.toggle() }
        if showAll || suggested.isEmpty {
            choices(MeshCorePresets.all.filter { p in !suggested.contains(p) }, current: current)
        }
    }

    /// What picking this preset means: a retune, a deprecated preset, route-hash size.
    @ViewBuilder private func radioNotices(_ me: MeshCore.SelfInfo) -> some View {
        if case .preset(let t) = radio, let p = MeshCorePresets.named(t) {
            if !p.matches(frequency: me.frequency, bandwidth: me.bandwidth, spreadingFactor: me.spreadingFactor, codingRate: me.codingRate) {
                Notice(text: "This retunes the node: it stops hearing anyone still on its old settings.", color: Theme.amber)
            }
            if p.deprecated {
                Notice(text: "MeshCore marks this preset deprecated. Use it only if your local mesh is still on it.", color: Theme.amber)
            }
            if let n = p.pathHashSize, n > 1 {
                Notice(text: "This mesh also uses \(n)-byte route hashes. Wildcat can't set that yet: set it to match in the MeshCore app.",
                       symbol: "info.circle")
            }
        }
    }

    private func choices(_ presets: [MeshCorePreset], current: MeshCorePreset?) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(presets.enumerated()), id: \.element.id) { i, p in
                if i > 0 { FieldDivider() }
                choiceRow(.preset(p.title), title: p.title, subtitle: p.summary,
                          tag: p == current ? "Now" : p.deprecated ? "Deprecated" : nil)
            }
        }
        .panel(.inset)
    }

    private func choiceRow(_ choice: RadioChoice, title: String, subtitle: String, tag: String?) -> some View {
        Button {
            radio = choice
            Haptics.selection()
        } label: {
            ChoiceRow(selected: radio == choice, title: title, subtitle: subtitle, tag: tag)
        }
        .buttonStyle(.rowPress)
    }

    @ViewBuilder private func namePage(_ me: MeshCore.SelfInfo) -> some View {
        ExplainerPanel("What should people see?",
                       text: "Your node's name travels in its adverts: it's what other people see in their contacts and on maps. Pick something they'll recognise, like a call sign or a first name and a place.")
        VStack(alignment: .leading, spacing: 8) {
            LabeledField(title: "Node name", text: $name, prompt: "e.g. MAYA Trail")
                .onChange(of: name) { _, v in
                    let c = MeshCoreNodeLimits.clamp(v)
                    if c != v { name = c }
                }
            HStack {
                Text(MeshCoreSetupCheck.isDefaultName(me.name, publicKey: me.publicKey)
                     ? "Now: \(me.name.isEmpty ? "no name" : me.name) (the firmware's default)" : "Now: \(me.name)")
                Spacer()
                Text("\(name.utf8.count)/\(MeshCoreNodeLimits.maxNameBytes) bytes")
            }
            .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
        }
        if nameProblem(me) != nil {
            Notice(text: nameProblem(me) ?? "", symbol: "info.circle")
        }
    }

    @ViewBuilder private func positionPage(_ me: MeshCore.SelfInfo) -> some View {
        ExplainerPanel("Put this node on the map?",
                       text: "Adverts can carry a position, so your node shows up on other people's maps (in MeshCore and in Wildcat). If you share, Wildcat sets it once to where this phone is now; it doesn't follow you around afterwards. You can change or clear it any time in Node settings.")
        VStack(spacing: 0) {
            Button { share = true; Haptics.selection() } label: {
                ChoiceRow(selected: share, title: "Share where I am", subtitle: "Others see this node on their maps", symbol: "mappin.and.ellipse")
            }
            .buttonStyle(.rowPress)
            FieldDivider()
            Button { share = false; Haptics.selection() } label: {
                ChoiceRow(selected: !share, title: "Don't share my position", subtitle: "Adverts carry the name only", symbol: "mappin.slash")
            }
            .buttonStyle(.rowPress)
        }
        .panel(.inset)
        if share {
            MetaLine(me.position.map { "Now: " + MeshCoreFormat.minus(String(format: "%.5f, %.5f", $0.latitude, $0.longitude)) + " (replaced by where you are)" }
                     ?? "Wildcat asks for your location once, when you apply.")
        }
    }

    @ViewBuilder private var channelPage: some View {
        let privateCount = link.session.channels.keys.filter { $0 > 0 }.count
        ExplainerPanel("Start a private channel?",
                       text: "Public is open to everyone on MeshCore nearby. A private channel has its own random key: only nodes you share it with can read it. You'll get a QR code to show friends; they scan it in Wildcat or the MeshCore app.")
        VStack(spacing: 0) {
            Button { makeChannel = true; Haptics.selection() } label: {
                ChoiceRow(selected: makeChannel, title: "Create a private channel", subtitle: "A new random 128-bit key", symbol: "lock")
            }
            .buttonStyle(.rowPress)
            FieldDivider()
            Button { makeChannel = false; Haptics.selection() } label: {
                ChoiceRow(selected: !makeChannel, title: "Skip for now",
                          subtitle: privateCount > 0 ? "This node already has \(privateCount) private channel\(privateCount == 1 ? "" : "s")" : "Add one later in Channels",
                          symbol: "arrow.uturn.right")
            }
            .buttonStyle(.rowPress)
        }
        .panel(.inset)
        if makeChannel {
            LabeledField(title: "Channel name", text: $channelName, prompt: "e.g. Trail Crew")
                .onChange(of: channelName) { _, v in
                    let c = MeshCoreNodeLimits.clamp(v, maxBytes: MeshCoreChannelCode.maxNameBytes)
                    if c != v { channelName = c }
                }
            if let p = channelProblem { Notice(text: p, symbol: "info.circle") }
        }
    }

    @ViewBuilder private func reviewPage(_ me: MeshCore.SelfInfo) -> some View {
        ModuleHeader(1, "Review")
        VStack(spacing: 0) {
            reviewRow("antenna.radiowaves.left.and.right", "Radio", radioReview(me))
            FieldDivider()
            reviewRow("textformat", "Name", trimmedName == me.name ? "\(me.name) (unchanged)" : trimmedName)
            FieldDivider()
            reviewRow(share ? "mappin.and.ellipse" : "mappin.slash", "Position",
                      share ? "Shared in adverts, set to where you are" : "Not shared")
            FieldDivider()
            reviewRow("lock", "Channel", makeChannel ? "Create \(trimmedChannel) (random key)" : "None now")
        }
        .panel(.inset)
        ModuleHeader(2, "First advert")
        VStack(spacing: 0) {
            Toggle(isOn: $advert) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send a first advert").font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                    Text("Floods across the mesh so nodes nearby learn about yours and can add it.")
                        .font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, Theme.Space.rowH)
            .padding(.vertical, Theme.Space.rowV)
        }
        .panel(.inset)
        .toggleStyle(FieldToggleStyle())
        if link.isDemo {
            Notice(text: "Practice: nothing goes on air.", symbol: "info.circle")
        }
    }

    @ViewBuilder private var applyPage: some View {
        statusNotice
        ModuleHeader(1, "Steps")
        VStack(spacing: 0) {
            ForEach(Array(apply.progress.enumerated()), id: \.offset) { i, step in
                if i > 0 { FieldDivider() }
                HStack(spacing: 12) {
                    Group {
                        switch step.state {
                        case .waiting: Image(systemName: "circle").foregroundStyle(Theme.textQuaternary)
                        case .working: ProgressView().tint(Theme.textSecondary)
                        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.alert)
                        }
                    }
                    .frame(width: 22)
                    Text(step.title).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, Theme.Space.rowH)
                .padding(.vertical, Theme.Space.rowV)
            }
        }
        .panel(.inset)
        if case .done = apply.status, let i = slot.value, let c = link.session.channels[i] {
            let code = MeshCoreChannelCode(name: c.name, key: c.secret)
            ModuleHeader(2, "Share \(c.name)")
            VStack(alignment: .leading, spacing: 12) {
                Text("Friends scan this in Wildcat or the MeshCore app to join. Anyone with the code can read the channel.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                QRImage(text: code.link).frame(maxWidth: 220).frame(maxWidth: .infinity)
                HStack {
                    Button { UIPasteboard.general.string = code.link; Haptics.success() } label: {
                        Label("Copy link", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.field(.secondary, .small))
                    ShareLink(item: code.link) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.field(.secondary, .small))
                }
            }
            .panel(.hero)
        }
    }

    @ViewBuilder private var statusNotice: some View {
        switch apply.status {
        case .idle: EmptyView()
        case .working(let t):
            HStack(spacing: 10) { ProgressView().tint(Theme.textSecondary); Text(t).font(Theme.Fonts.data) }
                .frame(maxWidth: .infinity, alignment: .leading).panel(.row)
        case .done(let t): Notice(text: t, color: Theme.ok, symbol: "checkmark.circle")
        case .failed(let t): Notice(text: t, color: Theme.alert, symbol: "exclamationmark.triangle")
        }
    }

    private func reviewRow(_ symbol: String, _ title: String, _ value: String) -> some View {
        FieldRow(symbol: symbol, title: title, subtitle: value, chevron: false)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if page != .radio && page != .apply {
                Button { go(-1) } label: { Text("Back").frame(maxWidth: .infinity) }
                    .buttonStyle(.field(.secondary, .large))
                    .frame(maxWidth: 120)
            }
            switch page {
            case .review:
                Button { Task { await run() } } label: {
                    Label("Apply", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.fieldPrimary)
            case .apply:
                switch apply.status {
                case .failed:
                    Button { page = .review; apply.reset() } label: { Text("Back").frame(maxWidth: .infinity) }
                        .buttonStyle(.field(.secondary, .large))
                    Button { Task { await run() } } label: { Label("Try again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                        .buttonStyle(.fieldPrimary)
                case .done:
                    Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }
                        .buttonStyle(.fieldPrimary)
                default:
                    Button {} label: { Text(locating ? "Finding you…" : "Applying…").frame(maxWidth: .infinity) }
                        .buttonStyle(.fieldPrimary)
                        .disabled(true)
                }
            default:
                Button { go(1) } label: { Text("Next").frame(maxWidth: .infinity) }
                    .buttonStyle(.fieldPrimary)
                    .disabled(!canAdvance)
            }
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.bg.opacity(0.94))
    }

    private var applyWord: String {
        switch apply.status {
        case .done: return "Done"
        case .failed: return "Stopped"
        default: return "Applying"
        }
    }

    private func go(_ by: Int) {
        guard let next = Page(rawValue: page.rawValue + by) else { return }
        // Put the keyboard away: the next page has no field for it.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        page = next
        Haptics.tap()
    }

    private var canAdvance: Bool {
        guard let me = link.session.me else { return false }
        switch page {
        case .name: return nameProblem(me) == nil
        case .channel: return !makeChannel || channelProblem == nil
        default: return true
        }
    }

    // MARK: Values

    private var regionName: String? {
        regionCode.flatMap { Locale.current.localizedString(forRegionCode: $0) }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedChannel: String { channelName.trimmingCharacters(in: .whitespaces) }

    private func nameProblem(_ me: MeshCore.SelfInfo) -> String? {
        if trimmedName.isEmpty { return "Give your node a name." }
        if MeshCoreSetupCheck.isDefaultName(trimmedName, publicKey: me.publicKey) {
            return "That's the firmware's default name. Pick one people will recognise."
        }
        return nil
    }

    private var channelProblem: String? {
        if trimmedChannel.isEmpty { return "Name the channel." }
        if trimmedChannel.hasPrefix("#") { return "Names starting with # are hashtag channels, which anyone can read. Join those from Channels." }
        if MeshCoreNodeLimits.freeChannelSlot(used: Set(link.session.channels.keys), maxChannels: link.session.device?.maxChannels) == nil {
            return "Every channel slot on this node is full."
        }
        return nil
    }

    private var chosenPreset: MeshCorePreset? {
        if case .preset(let t) = radio { return MeshCorePresets.named(t) }
        return nil
    }

    private func radioChanges(_ me: MeshCore.SelfInfo) -> Bool {
        guard let p = chosenPreset else { return false }
        return !p.matches(frequency: me.frequency, bandwidth: me.bandwidth, spreadingFactor: me.spreadingFactor, codingRate: me.codingRate)
    }

    private func radioReview(_ me: MeshCore.SelfInfo) -> String {
        guard let p = chosenPreset else {
            return (MeshCorePresets.match(me, regionCode: regionCode)?.title ?? "Custom") + " (unchanged)"
        }
        return radioChanges(me) ? "\(p.title): \(p.summary)" : "\(p.title) (unchanged)"
    }

    private func load() {
        guard !loaded, let me = link.session.me else { return }
        loaded = true
        if let now = MeshCorePresets.match(me, regionCode: regionCode) {
            radio = .preset(now.title)
        } else if let guess = MeshCorePresets.guess(regionCode: regionCode) {
            radio = .preset(guess.title)
        }
        name = MeshCoreSetupCheck.isDefaultName(me.name, publicKey: me.publicKey) ? "" : me.name
        share = me.advertLocationPolicy != 0
        makeChannel = !link.session.channels.keys.contains { $0 > 0 }
    }

    // MARK: Apply

    private func run() async {
        guard let me = link.session.me else { return }
        page = .apply
        var steps: [MeshCoreApply.Step] = []
        if trimmedName != me.name { steps.append(MeshCoreApply.name(trimmedName)) }
        if share {
            locating = true
            let here = await LocationOnce().get()
            locating = false
            if let here {
                steps.append(MeshCoreApply.position(Coordinate(latitude: here.coordinate.latitude, longitude: here.coordinate.longitude)))
            } else if me.position == nil {
                apply.fail("Wildcat couldn't get this phone's location. Allow location access, or go back and choose not to share.")
                return
            }
            if me.advertLocationPolicy == 0 { steps.append(MeshCoreApply.sharesPosition(true)) }
        } else if me.advertLocationPolicy != 0 {
            steps.append(MeshCoreApply.sharesPosition(false))
        }
        if radioChanges(me), let p = chosenPreset { steps.append(MeshCoreApply.radio(p)) }
        // On a retry, don't make the channel twice.
        let made = slot.value.flatMap { link.session.channels[$0] }?.name == trimmedChannel
        if makeChannel, !made {
            slot = MeshCoreSlotBox()
            steps.append(MeshCoreApply.channel(named: trimmedChannel, key: nil, slot: slot))
        }
        if advert { steps.append(MeshCoreApply.advert(flood: true)) }
        if steps.isEmpty {
            apply.finish("Nothing to change: this node is already set up that way.")
            return
        }
        if await apply.run(steps, on: link, summary: "\(trimmedName) is set up.") { Haptics.success() } else { Haptics.error() }
    }
}

/// A selectable row: a radio dot, a title and a line under it, maybe a tag.
struct ChoiceRow: View {
    let selected: Bool
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var tag: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(selected ? Theme.meshcore : Theme.textQuaternary)
            if let symbol { IconTile(symbol: symbol, tint: selected ? Theme.meshcore : nil) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary).lineLimit(2)
                if let subtitle {
                    Text(subtitle).font(Theme.Fonts.dataSmall).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let tag { Tag(tag) }
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
