import SwiftUI
import WildcatRadioCore

// MARK: - Console panel

/// "Heard on air" in the RNode console: counts since connecting, the newest few packets, and the
/// way to the full list. What the RNode hears is Reticulum packets on its own settings; Wildcat
/// reads their headers (kind, destination, hops), never their contents.
struct RNodeHeardPanel: View {
    /// The live session (`link.session`), or a sample in the design gallery.
    let session: RNodeSession

    var body: some View {
        let s = session
        let recent = Array(s.heard.prefix(3))
        VStack(alignment: .leading, spacing: 8) {
            InstrumentPanel {
                ReadoutRow {
                    ReadoutCell("Announces", value: "\(s.heardCounts[.announce])",
                                sub: RNodeHeardFormat.destinationsLine(s.announcers.count))
                    CellDivider()
                    ReadoutCell("Data", value: "\(s.heardCounts[.data])", sub: "encrypted to someone")
                    CellDivider()
                    ReadoutCell("Other", value: "\(RNodeHeardFormat.otherCount(s.heardCounts))",
                                sub: RNodeHeardFormat.otherLine(s.heardCounts))
                }
                PanelDivider()
                if recent.isEmpty {
                    Text(RNodeHeardFormat.emptyText(radioOn: s.parameters.radioOn == true))
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { t in
                        VStack(spacing: 0) {
                            ForEach(Array(recent.enumerated()), id: \.element.id) { i, h in
                                if i > 0 { FieldDivider() }
                                NavRow { RNodeHeardDetail(heard: h) } label: { RNodeHeardRow(heard: h, now: t.date) }
                            }
                        }
                    }
                }
            }
            NavRow { RNodeHeardView() } label: {
                FieldRow(symbol: "list.bullet.rectangle", tint: s.heard.isEmpty ? nil : RNodeStyle.color,
                         title: "Everything heard", subtitle: RNodeHeardFormat.sinceLine(s.heardSince, total: s.heardCounts.total),
                         detail: s.heard.isEmpty ? nil : "\(s.heard.count)")
                    .panel(.inset)
            }
        }
    }
}

// MARK: - The full list

/// Every packet the RNode heard this session (the newest 200), filterable by kind, with what
/// each header says. Tap one for the bytes.
struct RNodeHeardView: View {
    @Environment(RNodeLink.self) private var link

    var body: some View {
        RNodeHeardScreen(session: link.session, clear: { link.clearHeard() })
    }
}

/// The list itself, over any session (the live one, or a sample in the design gallery).
struct RNodeHeardScreen: View {
    let session: RNodeSession
    let clear: () -> Void
    @State private var filter: RNodeHeardFormat.Filter = .all
    @State private var confirmClear = false
    @State private var byDestination = false

    var body: some View {
        let s = session
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                Text(RNodeHeardFormat.countsLine(s.heardCounts, since: s.heardSince))
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                FieldSegmented(options: [(false, "Packets"), (true, "Announcers")], selection: $byDestination)
                if byDestination {
                    announcers(s)
                } else {
                    FieldSegmented(options: RNodeHeardFormat.Filter.allCases.map { ($0, $0.title) }, selection: $filter)
                    packets(s.heard(kinds: filter.kinds))
                }
                RNodeHeardExplainer()
            }
            .padding(.horizontal, Theme.Space.edge)
            .padding(.vertical, 12)
        }
        .screen()
        .navigationTitle("Heard on air")
        .navigationBarTitleDisplayMode(.inline)
        .tint(RNodeStyle.color)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear") { confirmClear = true }.disabled(s.heard.isEmpty && s.heardCounts.total == 0)
            }
        }
        .confirmationDialog("Clear the heard list?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { clear() }
        } message: {
            Text("The list and its counts start again from now.")
        }
    }

    @ViewBuilder private func packets(_ list: [RNodeSession.HeardPacket]) -> some View {
        if list.isEmpty {
            EmptyState(symbol: "waveform", title: filter == .all ? "Nothing heard yet" : "None of these yet",
                       text: RNodeHeardFormat.emptyText(radioOn: session.parameters.radioOn == true))
                .panel(.inset)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { t in
                LazyVStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, h in
                        if i > 0 { FieldDivider() }
                        NavRow { RNodeHeardDetail(heard: h) } label: { RNodeHeardRow(heard: h, now: t.date) }
                    }
                }
                .panel(.inset)
            }
        }
    }

    @ViewBuilder private func announcers(_ s: RNodeSession) -> some View {
        let list = s.announcers
        if list.isEmpty {
            EmptyState(symbol: "dot.radiowaves.up.forward", title: "No announces yet",
                       text: "Reticulum nodes announce their destinations now and then (Sideband on start-up and when it connects a radio, or with Announce Now). Each one shows here once.")
                .panel(.inset)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { t in
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { FieldDivider() }
                        NavRow { RNodeHeardDetail(heard: a.latest) } label: { RNodeAnnouncerRow(announcer: a, now: t.date) }
                    }
                }
                .panel(.inset)
            }
        }
    }
}

/// One heard packet in a list: kind, destination, hops and size, signal and age.
struct RNodeHeardRow: View {
    let heard: RNodeSession.HeardPacket
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: RNodeHeardFormat.symbol(heard.kind), tint: RNodeHeardFormat.tint(heard.kind))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(heard.kind.word).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let p = heard.packet {
                        Text(RNodeHeardFormat.destination(p)).font(Theme.Fonts.dataSmall).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Text(RNodeHeardFormat.subtitle(heard, snr: false))
                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 5) {
                if heard.rssi != nil || heard.snr != nil {
                    SegmentMeter(lit: SignalGrade.bars(snr: heard.snr, rssi: heard.rssi), of: 5, tint: RNodeStyle.color)
                }
                Text(MeshCoreFormat.ago(heard.at, now: now, short: true))
                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A destination that announced itself: how many times, how far, how loud the last one was.
struct RNodeAnnouncerRow: View {
    let announcer: RNodeSession.Announcer
    let now: Date

    var body: some View {
        let h = announcer.latest
        HStack(spacing: 12) {
            IconTile(symbol: RNodeHeardFormat.symbol(.announce), tint: RNodeStyle.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(RNodeHeardFormat.destination(announcer.destinationHash))
                    .font(Theme.Fonts.dataBold).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(RNodeHeardFormat.announcerLine(announcer))
                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 5) {
                if h.rssi != nil || h.snr != nil {
                    SegmentMeter(lit: SignalGrade.bars(snr: h.snr, rssi: h.rssi), of: 5, tint: RNodeStyle.color)
                }
                Text(MeshCoreFormat.ago(h.at, now: now, short: true)).font(Theme.Fonts.raw).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, Theme.Space.rowH)
        .padding(.vertical, Theme.Space.rowV)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One packet

/// Everything the header says, the signal, and the bytes with the header picked out.
struct RNodeHeardDetail: View {
    let heard: RNodeSession.HeardPacket

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                HStack(spacing: 12) {
                    IconTile(symbol: RNodeHeardFormat.symbol(heard.kind), tint: RNodeHeardFormat.tint(heard.kind), size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(heard.kind.word).font(Theme.Fonts.title).foregroundStyle(Theme.textPrimary)
                        Text(RNodeHeardFormat.headline(heard))
                            .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                RawPacketView(data: heard.packet?.raw ?? Data(), fields: RNodeHeardFormat.fields(heard),
                              title: "Heard on air", detail: "\(heard.size) B · \(RNodeHeardFormat.clock(heard.at))",
                              highlights: RNodeHeardFormat.highlights(heard).map { ByteHighlight(range: $0, color: RNodeStyle.color) },
                              emphasis: heard.packet == nil ? nil : 0..<2)
                Text(RNodeHeardFormat.note(heard))
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.edge)
        }
        .screen()
        .navigationTitle(heard.kind.word)
        .navigationBarTitleDisplayMode(.inline)
        .tint(RNodeStyle.color)
    }
}

/// What the list can and can't show, in plain words.
struct RNodeHeardExplainer: View {
    var body: some View {
        ExplainerPanel("What is this?",
                       text: "Every Reticulum packet the RNode hears on its frequency and settings. Wildcat reads the header: the kind, the destination it's for and how many hops it has come. The rest is encrypted to that destination; announces are signed, and checking them is the Reticulum stack's job.") {
            VStack(alignment: .leading, spacing: 6) {
                Text("It can't hear Meshtastic or MeshCore: the RNode listens on Reticulum's own LoRa sync word. “Access code” packets come from a network with a name and passphrase set. Signal is the RNode's reading for each packet; in a quick burst a packet may carry the next one's numbers.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Formatting

enum RNodeHeardFormat {
    enum Filter: Hashable, CaseIterable {
        case all, announces, data, other

        var title: String {
            switch self {
            case .all: return "All"
            case .announces: return "Announces"
            case .data: return "Data"
            case .other: return "Other"
            }
        }

        var kinds: Set<ReticulumPacket.Kind> {
            switch self {
            case .all: return []
            case .announces: return [.announce]
            case .data: return [.data]
            case .other: return [.pathRequest, .linkRequest, .proof, .masked, .unreadable]
            }
        }
    }

    /// "<53802fdd…>": the start of a destination hash, bracketed the way Reticulum prints hashes.
    static func destination(_ p: ReticulumPacket) -> String { destination(p.destinationHash) }

    static func destination(_ hash: Data) -> String {
        hash.count > 4 ? "<\(ReticulumPacket.hex(hash.prefix(4)))…>" : "<\(ReticulumPacket.hex(hash))>"
    }

    /// "<53802fddcecac99e39bf6144e3e1de1d>"
    static func fullHash(_ hash: Data) -> String { "<\(ReticulumPacket.hex(hash))>" }

    /// "direct", "1 hop", "3 hops".
    static func hops(_ n: Int) -> String { n == 0 ? "direct" : n == 1 ? "1 hop" : "\(n) hops" }

    /// "single · direct · 188 B · −101 dBm · SNR 6.5", "via transport · 1 hop · 190 B", "masked · 204 B".
    /// Rows leave the SNR out (their meter shows the signal).
    static func subtitle(_ h: RNodeSession.HeardPacket, snr: Bool = true) -> String {
        var parts: [String] = []
        switch h.reading {
        case .packet(let p):
            parts.append(p.headerType == .type2 ? "via transport" : p.destinationType.word)
            parts.append(hops(p.hops))
            if let c = p.contextName { parts.append(c) }
        case .masked:
            parts.append("masked")
        case .unreadable:
            parts.append("not Reticulum")
        }
        parts.append("\(h.size) B")
        if snr, let s = signal(h) { parts.append(s) } else if !snr, let r = h.rssi { parts.append(MeshCoreFormat.minus("\(r) dBm")) }
        return parts.joined(separator: " · ")
    }

    /// "−101 dBm · SNR 6.5".
    static func signal(_ h: RNodeSession.HeardPacket) -> String? {
        let parts = [h.rssi.map { MeshCoreFormat.minus("\($0) dBm") }, h.snr.map { "SNR " + MeshCoreFormat.number($0, digits: 2) }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "5:02:31 PM" or "17:02:31", as the phone tells time.
    static func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .standard) }

    /// One plain sentence under the kind on the detail screen.
    static func headline(_ h: RNodeSession.HeardPacket) -> String {
        switch h.reading {
        case .masked:
            return "From a Reticulum network with an access code (a network name or passphrase). Without them nothing past the first byte can be read."
        case .unreadable(let problem):
            return "Not a Reticulum packet: \(problem.text). Noise, a damaged frame, or another LoRa system on the same settings."
        case .packet(let p):
            let to = fullHash(p.destinationHash)
            switch p.kind {
            case .announce:
                return "\(to) told the network it exists and how to reach it, \(p.hops == 0 ? "heard directly" : "after \(hops(p.hops))")."
            case .pathRequest:
                return "Someone asked the network for a way to reach a destination."
            case .linkRequest:
                return "Someone is opening an encrypted link to \(to)."
            case .proof:
                return "A delivery proof: the receiver confirming a packet arrived."
            case .data:
                return p.destinationType == .plain
                    ? "Unencrypted data to the plain destination \(to)."
                    : "Encrypted data for \(to)\(p.destinationType == .link ? " (a link)" : "")."
            case .masked, .unreadable:
                return ""
            }
        }
    }

    /// The decoded fields for the raw packet drawer.
    static func fields(_ h: RNodeSession.HeardPacket) -> [(label: String, value: String)] {
        var out: [(label: String, value: String)] = []
        if let p = h.packet {
            out.append(("Kind", p.kind.word))
            out.append(("Destination", ReticulumPacket.hex(p.destinationHash)))
            out.append(("Dest type", p.destinationType.word))
            out.append(("Hops", "\(p.hops)"))
            out.append(("Header", p.headerType == .type2 ? "type 2 (in transport)" : "type 1"))
            if let t = p.transportID { out.append(("Transport", ReticulumPacket.hex(t))) }
            out.append(("Propagation", p.propagation == .transport ? "transport" : "broadcast"))
            out.append(("Context", p.contextName.map { "\($0) (0x\(String(format: "%02x", p.context)))" } ?? String(format: "none (0x%02x)", p.context)))
            out.append(("Ctx flag", p.contextFlag ? "set" : "unset"))
            out.append(("Data", "\(p.dataLength) B"))
        } else if case .unreadable(let problem) = h.reading {
            out.append(("Problem", problem.text))
        } else {
            out.append(("IFAC", "set: masked by an access code"))
        }
        out.append(("Size", "\(h.size) B · \(h.airFrames) frame\(h.airFrames == 1 ? "" : "s")"))
        if let ms = h.airtimeMs { out.append(("Airtime", "≈ \(ms) ms")) }
        if let r = h.rssi { out.append(("RSSI", MeshCoreFormat.minus("\(r) dBm"))) }
        if let s = h.snr { out.append(("SNR", MeshCoreFormat.db(s))) }
        out.append(("Heard", clock(h.at)))
        return out
    }

    /// Byte ranges to colour: the address or addresses and the context byte.
    static func highlights(_ h: RNodeSession.HeardPacket) -> [Range<Int>] {
        guard let p = h.packet else { return [] }
        return [2..<p.headerLength]
    }

    /// The footnote on the detail screen.
    static func note(_ h: RNodeSession.HeardPacket) -> String {
        switch h.reading {
        case .packet:
            return "Highlighted: the flags and hops, then the address\(h.packet?.headerType == .type2 ? "es" : "") and context. The rest is the packet's data, encrypted to its destination (or signed, for an announce). The RNode removed its own 1-byte LoRa header before passing this on."
        case .masked:
            return "Interface access codes keep a Reticulum network private on a shared channel. Wildcat would need the same network name and passphrase as the senders to read these."
        case .unreadable:
            return "The RNode passes on anything it receives cleanly on its frequency and settings and sync word, after removing the first byte as its own header."
        }
    }

    /// "12 announces · 4 data · 3 other, since 17:02".
    static func countsLine(_ c: RNodeSession.HeardCounts, since: Date?) -> String {
        guard c.total > 0 else { return since.map { "Nothing heard since \(clock($0))." } ?? "Nothing heard yet." }
        var parts = ["\(c[.announce]) announce\(c[.announce] == 1 ? "" : "s")", "\(c[.data]) data"]
        let other = otherCount(c)
        if other > 0 { parts.append("\(other) other") }
        return parts.joined(separator: " · ") + (since.map { ", since \(clock($0))" } ?? "") + "."
    }

    static func otherCount(_ c: RNodeSession.HeardCounts) -> Int { c.total - c[.announce] - c[.data] }

    /// "2 path requests, 1 masked" (the largest two of the other kinds), or what "other" means.
    static func otherLine(_ c: RNodeSession.HeardCounts) -> String {
        let kinds: [ReticulumPacket.Kind] = [.pathRequest, .linkRequest, .proof, .masked, .unreadable]
        // Most first; ties keep the order above.
        let ranked = kinds.enumerated().filter { c[$0.element] > 0 }
            .sorted { (c[$0.element], -$0.offset) > (c[$1.element], -$1.offset) }.map(\.element)
        let parts = ranked.prefix(2).map { "\(c[$0]) \(shortWord($0, c[$0]))" }
        guard !parts.isEmpty else { return "links, proofs, paths" }
        return parts.joined(separator: ", ") + (ranked.count > 2 ? ", +\(ranked.count - 2) more" : "")
    }

    private static func shortWord(_ k: ReticulumPacket.Kind, _ n: Int) -> String {
        switch k {
        case .pathRequest: return n == 1 ? "path request" : "path requests"
        case .linkRequest: return n == 1 ? "link" : "links"
        case .proof: return n == 1 ? "proof" : "proofs"
        case .masked: return "masked"
        case .unreadable: return "unreadable"
        case .announce, .data: return k.word.lowercased()
        }
    }

    /// "from 3 destinations", "from 1 destination", "none yet".
    static func destinationsLine(_ n: Int) -> String { n == 0 ? "none yet" : "from \(n) destination\(n == 1 ? "" : "s")" }

    /// "2 announces · direct · −98 dBm" (the latest one's hops and RSSI).
    static func announcerLine(_ a: RNodeSession.Announcer) -> String {
        var parts = ["\(a.count) announce\(a.count == 1 ? "" : "s")"]
        if let p = a.latest.packet { parts.append(hops(p.hops)) }
        if let r = a.latest.rssi { parts.append(MeshCoreFormat.minus("\(r) dBm")) }
        return parts.joined(separator: " · ")
    }

    /// "Since 17:02 · 42 packets", or what the row is for.
    static func sinceLine(_ since: Date?, total: Int) -> String {
        guard let since, total > 0 else { return "Every packet, with what its header says" }
        return "\(total) packet\(total == 1 ? "" : "s") since \(clock(since))"
    }

    static func emptyText(radioOn: Bool) -> String {
        radioOn
            ? "Listening. Packets show here as the RNode hears them: Reticulum nodes on the same frequency, bandwidth, spreading factor and coding rate."
            : "The radio is off, so the RNode hears nothing. Set its radio and turn it on to listen; Wildcat never transmits from here."
    }

    static func symbol(_ k: ReticulumPacket.Kind) -> String {
        switch k {
        case .announce: return "dot.radiowaves.up.forward"
        case .data: return "lock.square"
        case .pathRequest: return "point.topleft.down.to.point.bottomright.curvepath"
        case .linkRequest: return "link"
        case .proof: return "checkmark.seal"
        case .masked: return "eye.slash"
        case .unreadable: return "questionmark.square.dashed"
        }
    }

    static func tint(_ k: ReticulumPacket.Kind) -> Color? {
        switch k {
        case .announce: return RNodeStyle.color
        case .data, .pathRequest, .linkRequest, .proof: return nil
        case .masked: return Theme.warn
        case .unreadable: return Theme.textTertiary
        }
    }
}
