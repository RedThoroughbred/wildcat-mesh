import CoreLocation
import MapKit
import SwiftUI
import WildcatRadioCore

/// Every node your own radio knows (the Meshtastic app's node list).
struct NodesView: View {
    @Environment(Radio.self) private var radio
    @Environment(MyMeshStore.self) private var myMesh
    @State private var query = ""
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable { case all = "All", direct = "Direct", favorites = "Favorites" }

    private var known: [NodeInfo] {
        let me = radio.session.myNode
        return radio.session.nodes.values.filter { $0.num != me && !$0.isIgnored }
    }

    private func matches(_ n: NodeInfo, _ f: Filter) -> Bool {
        switch f {
        case .all: return true
        case .direct: return n.hopsAway == 0 && !n.viaMQTT
        case .favorites: return n.isFavorite
        }
    }

    private var nodes: [NodeInfo] {
        known
            .filter { matches($0, filter) }
            .filter { query.isEmpty || [$0.shortName, $0.longName, $0.num.id, $0.hardware].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) } }
            .sorted {
                if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
                return ($0.lastHeard ?? .distantPast) > ($1.lastHeard ?? .distantPast)
            }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.stack) {
                FieldSegmented(options: Filter.allCases.map { f in (f, "\(f.rawValue) \(known.filter { matches($0, f) }.count)") },
                               selection: $filter)
                ModuleHeader(nil, "Heard by \(radio.session.myNode.flatMap { radio.session.nodes[$0]?.shortName } ?? "your node")",
                             detail: "\(nodes.count)") {
                    NetworkTag(.meshtastic)
                }
                if nodes.isEmpty {
                    EmptyState(symbol: "point.3.connected.trianglepath.dotted", title: "No nodes here",
                               text: query.isEmpty ? "Nothing matches this filter yet." : "Nothing matches \(query).")
                        .panel()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(nodes.enumerated()), id: \.element.num) { i, n in
                            if i > 0 { FieldDivider() }
                            NavRow { NodeDetailView(num: n.num) } label: {
                                HeardRow(node: n, mine: myMesh.contains(OwnedNode.id(.meshtastic, n.num.id)), chevron: true)
                            }
                        }
                    }
                    .panel(.inset)
                }
                Text("Signal bars show nodes your radio hears directly. Relayed nodes show how many hops away they are.")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .searchable(text: $query, prompt: "Name, ID or hardware")
        .navigationTitle("Nodes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A node in a list, without its own padding (kept for callers that pad rows themselves).
struct NodeRow: View {
    let node: NodeInfo

    var body: some View {
        var row = HeardRow(node: node)
        row.padded = false
        return row
    }
}

// MARK: - Node detail

struct NodeDetailView: View {
    @Environment(Radio.self) private var radio
    @Environment(NodeAdmin.self) private var admin
    @Environment(Traceroutes.self) private var traceroutes
    @Environment(MyMeshStore.self) private var myMesh
    @Environment(\.dismiss) private var dismiss
    @Environment(Safety.self) private var safety
    let num: NodeNum
    @State private var confirmRemove = false
    @State private var confirmBlock = false
    @State private var openChat = false

    var body: some View {
        let n = radio.session.nodes[num] ?? NodeInfo(num: num)
        let mine = myMesh.contains(OwnedNode.id(.meshtastic, num.id))
        let working = !radio.isReady || admin.isWorking
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.stack) {
                header(n)
                StatusKeyRow {
                    StatusKey("Message", symbol: "bubble.left") { openChat = true }
                    StatusKey("Trace", symbol: "point.topleft.down.to.point.bottomright.curvepath", primary: traceroutes.canSend) {
                        traceroutes.run(to: num)
                    }
                    .disabled(!traceroutes.canSend)
                    StatusKey(n.isFavorite ? "Unstar" : "Star", symbol: n.isFavorite ? "star.slash" : "star") {
                        Task { await admin.apply([.favorite(num, !n.isFavorite)], summary: n.isFavorite ? "Unfavourite" : "Favourite") }
                    }
                    .disabled(working)
                    StatusKey(mine ? "Mine" : "My Mesh", symbol: mine ? "checkmark.seal" : "plus.circle", led: mine ? .on : .none) {
                        if mine { myMesh.remove(OwnedNode.id(.meshtastic, num.id)) } else { myMesh.markMine(.meshtastic(n)) }
                    }
                }
                roleModule(n)
                linkModule(n)
                traceModule
                if let p = n.position { positionModule(n, p) }
                rawModule(n)
                safetyModule(n, blocked: safety.hides(meshtasticNode: num.id))
                    .disabled(working)
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationTitle(n.shortName ?? num.short)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $openChat) { ConversationView(conversation: .direct(num.id)) }
        .confirmationDialog("Block \(n.shortName ?? num.short)?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) { safety.block(.node(n)); Haptics.thud() }
        } message: {
            Text("Its messages disappear from Wildcat, you get no notifications from it, and the bridge won't relay it. Your node ignores it too.")
        }
        .confirmationDialog("Forget this node on your radio?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await admin.apply([.remove(num)], summary: "Removal")
                    dismiss()
                }
            }
        }
    }

    private var myName: String {
        radio.source == .practice ? "your practice node"
            : radio.session.myNode.flatMap { radio.session.nodes[$0]?.longName ?? radio.session.nodes[$0]?.shortName } ?? "your node"
    }

    private func header(_ n: NodeInfo) -> some View {
        let online = n.lastHeard.map { Date().timeIntervalSince($0) < 2 * 3600 } ?? false
        return HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: MeshtasticSummary.symbol(role: n.role, viaMQTT: n.viaMQTT), tint: Theme.meshtastic, size: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text(n.longName ?? num.id)
                    .font(.system(.title, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 6) {
                    Tag(roleTitle(n.role))
                    NetworkTag(.meshtastic)
                    Text(num.id).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    StatusLED(color: Theme.ok, on: online, size: 6)
                    Text("\(online ? "Online" : "Last") · heard \(MeshtasticSummary.ago(n.lastHeard)) via \(myName)")
                        .font(Theme.Fonts.detail)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }

    // 01 ROLE: what this kind of node is, and the path to it.
    private func roleModule(_ n: NodeInfo) -> some View {
        let e = MeshtasticSummary.explainer(role: n.role)
        return VStack(alignment: .leading, spacing: 8) {
            ModuleHeader(1, "Role")
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(e.title, systemImage: "questionmark.circle")
                        .font(Theme.Fonts.heading)
                        .foregroundStyle(Theme.textPrimary)
                    Text(e.text)
                        .font(Theme.Fonts.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                PanelDivider().padding(.horizontal, 14)
                PathStrip(hops: hopsLine(n))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .panel(.inset)
        }
    }

    /// You → relays → this node, with the signal of each hop when a trace has answered.
    private func hopsLine(_ n: NodeInfo) -> [PathStrip.Stop] {
        let name = { (x: NodeNum) in self.radio.session.nodes[x]?.shortName ?? self.radio.session.label(for: x) }
        let end = PathStrip.Stop(name: n.shortName ?? num.short, symbol: MeshtasticSummary.symbol(role: n.role, viaMQTT: n.viaMQTT))
        if case .answered(let r, _)? = traceroutes.results[num] {
            var stops = [PathStrip.Stop(name: "You", symbol: "person")]
            for (i, hop) in r.towards.enumerated() {
                stops[stops.count - 1].snrAfter = i < r.snrTowards.count ? r.snrTowards[i] : nil
                stops.append(PathStrip.Stop(name: name(hop), symbol: MeshtasticSummary.symbol(role: radio.session.nodes[hop]?.role)))
            }
            stops[stops.count - 1].snrAfter = r.towards.count < r.snrTowards.count ? r.snrTowards[r.towards.count] : nil
            return stops + [end]
        }
        var you = PathStrip.Stop(name: "You", symbol: "person")
        if n.viaMQTT {
            you.note = "internet"
        } else if n.hopsAway == 0 {
            you.snrAfter = n.snr.map(Double.init)
        } else if let h = n.hopsAway {
            you.note = "\(h) hop\(h == 1 ? "" : "s")"
        }
        return [you, end]
    }

    // 02 LINK: SNR, hops, battery, last heard.
    private func linkModule(_ n: NodeInfo) -> some View {
        let direct = n.hopsAway == 0 && !n.viaMQTT
        let snr = n.snr.map(Double.init)
        let grade = direct ? SignalGrade.grade(snr: snr, rssi: nil) : .none
        let m = n.metrics
        return VStack(alignment: .leading, spacing: 8) {
            ModuleHeader(2, "Link") {
                Text([direct && grade != .none ? grade.word : nil, MeshtasticSummary.path(hops: n.hopsAway, viaMQTT: n.viaMQTT)?.lowercased()]
                        .compactMap { $0 }.joined(separator: " · "))
            }
            ReadoutRow {
                ReadoutCell("SNR", value: snr.map { MeshtasticSummary.signed($0, digits: 2) } ?? "—", unit: snr == nil ? nil : "dB",
                            sub: direct ? nil : "last hop") {
                    if direct, let snr { SegmentMeter(lit: SignalGrade.bars(snr: snr, rssi: nil), of: 5, tint: Theme.meshtastic, size: .xs) }
                }
                CellDivider()
                ReadoutCell("Hops", value: n.viaMQTT ? "—" : n.hopsAway.map(String.init) ?? "—",
                            sub: n.viaMQTT ? "internet" : n.hopsAway == 0 ? "direct" : nil)
                CellDivider()
                ReadoutCell("Batt", value: battery(m).value, unit: battery(m).unit,
                            sub: m?.uptime.map { "up " + DenFormat.duration(Double($0)) })
                CellDivider()
                ReadoutCell("Heard", value: n.lastHeard.map { DenFormat.ago($0) } ?? "—", sub: "ago")
            }
            .instrumentPanel()
        }
    }

    private func battery(_ m: DeviceMetrics?) -> (value: String, unit: String?) {
        guard let m else { return ("—", nil) }
        if m.isPowered { return ("USB", nil) }
        if let v = m.voltage { return (String(format: "%.2f", v), "V") }
        if let b = m.batteryLevel { return ("\(b)", "%") }
        return ("—", nil)
    }

    // 03 TRACEROUTE
    private var traceModule: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModuleHeader(3, "Traceroute")
            VStack(alignment: .leading, spacing: 12) {
                switch traceroutes.results[num] {
                case .waiting?:
                    HStack(spacing: 10) {
                        ProgressView().tint(Theme.meshtastic)
                        Text("Waiting for the answer (up to a minute)…").font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                    }
                case .timedOut?:
                    Notice(text: "No answer. It may be out of range, asleep, or the path is busy.", color: Theme.alert)
                case .answered(let r, _)?:
                    RouteView(route: r, from: radio.session.myNode, to: num, label: { radio.session.label(for: $0) })
                case nil:
                    Text("Shows every hop between your node and this one, with the signal at each.")
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                }
                Button {
                    traceroutes.run(to: num)
                } label: { Label("Trace the route", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                .buttonStyle(.field(.secondary, .regular))
                .disabled(!traceroutes.canSend)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }

    // 04 POSITION
    private func positionModule(_ n: NodeInfo, _ p: Coordinate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ModuleHeader(4, "Position")
            VStack(spacing: 0) {
                Map(initialPosition: .region(MKCoordinateRegion(center: .init(latitude: p.latitude, longitude: p.longitude),
                                                                latitudinalMeters: 3000, longitudinalMeters: 3000))) {
                    Annotation(n.shortName ?? "", coordinate: .init(latitude: p.latitude, longitude: p.longitude)) {
                        MapDot(color: Theme.meshtastic)
                    }
                    UserAnnotation()
                }
                .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
                .frame(height: 170)
                Text([String(format: "%.4f, %.4f", p.latitude, p.longitude).replacingOccurrences(of: "-", with: "−"),
                      n.altitude.map { "\($0) m" }, n.positionTime.map { "fix " + DenFormat.ago($0) + " ago" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.Fonts.raw)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .panel(.inset)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        }
    }

    // 05 RAW
    private func rawModule(_ n: NodeInfo) -> some View {
        let items = rawItems(n)
        return VStack(alignment: .leading, spacing: 8) {
            ModuleHeader(n.position == nil ? 4 : 5, "Raw", action: "Copy all", symbol: "doc.on.doc") {
                UIPasteboard.general.string = KeyValueGrid.text(items)
                Haptics.success()
            }
            KeyValueGrid(items)
        }
    }

    private func rawItems(_ n: NodeInfo) -> [KeyValueItem] {
        var out = [KeyValueItem(key: "num", value: num.id, note: String(num.raw))]
        if let u = n.userID, u != num.id { out.append(KeyValueItem(key: "user", value: u)) }
        out.append(KeyValueItem(key: "names", value: [n.shortName, n.longName].compactMap { $0 }.joined(separator: " · ")))
        out.append(KeyValueItem(key: "hw", value: n.hardware ?? "—", note: n.hwModel.map { "#\($0)" }))
        out.append(KeyValueItem(key: "role", value: roleTitle(n.role).uppercased(), note: n.role.map { "0x" + String(format: "%02x", $0) }))
        if let s = n.snr { out.append(KeyValueItem(key: "snr", value: MeshtasticSummary.signed(Double(s), digits: 2) + " dB")) }
        out.append(KeyValueItem(key: "hops", value: n.hopsAway.map(String.init) ?? "—", note: n.viaMQTT ? "mqtt" : nil))
        if let c = n.channel { out.append(KeyValueItem(key: "channel", value: "\(c)", note: radio.session.channels[c]?.name)) }
        if let h = n.lastHeard {
            out.append(KeyValueItem(key: "heard", value: h.formatted(date: .omitted, time: .standard), note: DenFormat.ago(h)))
        }
        if let p = n.position {
            out.append(KeyValueItem(key: "pos", value: String(format: "%.4f, %.4f", p.latitude, p.longitude)
                .replacingOccurrences(of: "-", with: "−"), note: n.altitude.map { "\($0) m" }))
        }
        if let m = n.metrics {
            if let b = m.batteryLevel { out.append(KeyValueItem(key: "battery", value: m.isPowered ? "powered" : "\(b)%",
                                                                 note: m.voltage.map { String(format: "%.2f V", $0) })) }
            if let c = m.channelUtilization { out.append(KeyValueItem(key: "ch util", value: String(format: "%.1f %%", c),
                                                                      note: m.airUtilTx.map { String(format: "tx %.1f %%", $0) })) }
            if let u = m.uptime { out.append(KeyValueItem(key: "uptime", value: DenFormat.duration(Double(u)), note: "\(u) s")) }
        }
        return out
    }

    // 06 SAFETY: block (Meshtastic's ignore plus Wildcat's own list) and remove.
    private func safetyModule(_ n: NodeInfo, blocked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ModuleHeader(n.position == nil ? 5 : 6, "Safety")
            VStack(spacing: 0) {
                Button {
                    if blocked { safety.unblock(.node(n)) } else { confirmBlock = true }
                } label: {
                    FieldRow(symbol: "hand.raised", tint: blocked ? nil : Theme.alert, title: blocked ? "Unblock" : "Block",
                             subtitle: blocked ? "Blocked: hidden, and kept off the bridge" : "Hides its messages and keeps it off the bridge",
                             chevron: false)
                }
                .buttonStyle(.rowPress)
                FieldDivider()
                Button(role: .destructive) { confirmRemove = true } label: {
                    FieldRow(symbol: "trash", tint: Theme.alert, title: "Remove from node database",
                             subtitle: "Your node forgets it until it's heard again", chevron: false)
                }
                .buttonStyle(.rowPress)
            }
            .panel(.inset)
        }
    }
}

/// A horizontal path: You ‹snr› relay ‹snr› node (AB node detail).
struct PathStrip: View {
    struct Stop {
        var name: String
        var symbol: String
        /// The signal on the hop after this stop.
        var snrAfter: Double? = nil
        /// Instead of a signal: "2 hops", "internet".
        var note: String? = nil
    }

    let hops: [Stop]

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(Array(hops.enumerated()), id: \.offset) { i, s in
                VStack(spacing: 6) {
                    Image(systemName: s.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(i == 0 ? Theme.textSecondary : Theme.meshtastic)
                        .frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(i == 0 ? Theme.hairlineStrong : Theme.meshtastic.opacity(0.35), lineWidth: 1))
                    Text(s.name)
                        .font(.system(.caption))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(minWidth: 44)
                if i < hops.count - 1 {
                    VStack(spacing: 3) {
                        Text(s.snrAfter.map { MeshtasticSummary.signed($0) + " dB" } ?? s.note ?? "?")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle((s.snrAfter ?? 0) < 0 ? Theme.alert : Theme.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Line()
                            .stroke((s.snrAfter ?? 0) < 0 ? Theme.alert.opacity(0.7) : Theme.meshtastic.opacity(0.7),
                                    style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(height: 1)
                    }
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hops.map { $0.name }.joined(separator: " to "))
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return p
        }
    }
}

private struct RouteView: View {
    let route: Route
    let from: NodeNum?
    let to: NodeNum
    let label: (NodeNum) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardLabel("Out")
            path([from].compactMap { $0 } + route.towards + [to], snr: route.snrTowards)
            if !route.snrBack.isEmpty {
                CardLabel("Back")
                path([to] + route.back + [from].compactMap { $0 }, snr: route.snrBack)
            }
        }
    }

    private func path(_ nodes: [NodeNum], snr: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { i, n in
                if i > 0 {
                    HStack(spacing: 6) {
                        Rectangle().fill(Theme.hairlineStrong).frame(width: 1, height: 14).padding(.leading, 5)
                        Text(i - 1 < snr.count ? MeshtasticSummary.signed(snr[i - 1]) + " dB" : "?")
                            .font(Theme.Fonts.raw)
                            .foregroundStyle(i - 1 < snr.count && snr[i - 1] < 0 ? Theme.alert : Theme.textTertiary)
                    }
                }
                HStack(spacing: 8) {
                    Circle()
                        .strokeBorder(i == 0 || i == nodes.count - 1 ? Theme.meshtastic : Theme.textTertiary, lineWidth: 1.5)
                        .frame(width: 11, height: 11)
                    Text(label(n)).font(Theme.Fonts.data).foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }
}

// MARK: - Map

/// Where your radio's nodes are (AB map): range rings around you, tappable
/// pins, and a readout card with bearing, distance, hops and signal for the
/// selected node.
struct MeshMapView: View {
    @Environment(Radio.self) private var radio
    @Environment(Traceroutes.self) private var traceroutes
    @State private var selected: NodeNum?
    @State private var rings = true
    @State private var openChat: NodeNum?
    @State private var openInfo: NodeNum?
    @State private var phone: CLLocationCoordinate2D? = MeshMapView.lastPhoneLocation()
    @State private var camera: MapCameraPosition = .automatic
    @State private var framed = false

    /// Ring spacing that puts the farthest pin inside the third ring.
    private func ringStep(_ placed: [NodeInfo], _ center: LatLon?) -> Double {
        guard let center else { return 1000 }
        let far = placed.compactMap { n in n.position.map { Geo.distance(center, LatLon(lat: $0.latitude, lon: $0.longitude)) } }.max() ?? 0
        return MeshtasticSummary.ringStep(farthest: far)
    }

    /// First look: you in the middle, all rings in view (instead of framing the whole region).
    private func frame() {
        guard !framed, let center else { return }
        framed = true
        let span = ringStep(placed, center) * 3 * 2.3
        camera = .region(MKCoordinateRegion(center: center.coordinate, latitudinalMeters: span, longitudinalMeters: span))
    }

    /// The phone's last known position, without asking for permission.
    static func lastPhoneLocation() -> CLLocationCoordinate2D? {
        let m = CLLocationManager()
        guard m.authorizationStatus == .authorizedWhenInUse || m.authorizationStatus == .authorizedAlways else { return nil }
        return m.location?.coordinate
    }

    private var placed: [NodeInfo] {
        radio.session.nodes.values.filter { $0.position != nil && !$0.isIgnored && $0.num != radio.session.myNode }
            .sorted { $0.num < $1.num }
    }

    /// Where "you" are: the phone, else your node's own position.
    private var center: LatLon? {
        if let phone { return LatLon(lat: phone.latitude, lon: phone.longitude) }
        if let me = radio.session.myNode, let p = radio.session.nodes[me]?.position { return LatLon(lat: p.latitude, lon: p.longitude) }
        return nil
    }

    var body: some View {
        let placed = placed
        let center = center
        let step = ringStep(placed, center)
        Map(position: $camera, selection: $selected) {
            UserAnnotation()
            if rings, let center {
                ForEach([step, step * 2, step * 3], id: \.self) { r in
                    MapCircle(center: center.coordinate, radius: r)
                        .foregroundStyle(.clear)
                        .stroke(Color.white.opacity(0.32), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    Annotation("", coordinate: Geo.offset(center, distance: r, bearing: 0).coordinate) {
                        Text(r < 1000 ? "\(Int(r)) m" : "\((r / 1000).formatted()) km")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            if let center, let s = selected, let p = radio.session.nodes[s]?.position {
                MapPolyline(coordinates: [center.coordinate, .init(latitude: p.latitude, longitude: p.longitude)])
                    .stroke(Theme.meshtastic, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            }
            if let me = radio.session.myNode, let p = radio.session.nodes[me]?.position, phone == nil {
                Annotation("", coordinate: .init(latitude: p.latitude, longitude: p.longitude)) {
                    Circle().fill(Theme.textPrimary).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                        .background(Circle().fill(Color.white.opacity(0.12)).padding(-8))
                }
            }
            ForEach(placed, id: \.num) { n in
                if let p = n.position {
                    Annotation("", coordinate: .init(latitude: p.latitude, longitude: p.longitude), anchor: .leading) {
                        MeshPin(node: n, selected: selected == n.num)
                    }
                    .tag(n.num)
                }
            }
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .safeAreaInset(edge: .top) {
            HStack(spacing: 6) {
                MapChip(led: Theme.meshtastic, text: "Meshtastic", count: placed.count, on: true) {}
                MapChip(text: "Range", on: rings) { rings.toggle() }
                    .disabled(center == nil)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if let s = selected, let n = radio.session.nodes[s] {
                    SelectedNodeCard(node: n, from: center, onClose: { selected = nil },
                                     onMessage: { openChat = s }, onTrace: { traceroutes.run(to: s) },
                                     onInfo: { openInfo = s }, canTrace: traceroutes.canSend)
                } else if placed.isEmpty {
                    Notice(text: "No nodes have shared a position yet. They appear here when their position packets arrive.",
                           symbol: "mappin.slash")
                        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: Theme.Radius.s + 2, style: .continuous))
                }
            }
            .padding(12)
        }
        .onAppear { frame() }
        .navigationTitle("Mesh map")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openChat) { ConversationView(conversation: .direct($0.id)) }
        .navigationDestination(item: $openInfo) { NodeDetailView(num: $0) }
    }
}

/// A pin: amber diamond for relays, amber dot for everyone else, grey once stale;
/// the name and a small mono line beside it.
private struct MeshPin: View {
    let node: NodeInfo
    let selected: Bool

    private var stale: Bool { node.lastHeard.map { Date().timeIntervalSince($0) > 2 * 3600 } ?? true }

    var body: some View {
        let color = stale ? Theme.textTertiary : Theme.meshtastic
        HStack(alignment: .center, spacing: 5) {
            ZStack {
                if selected {
                    Circle().strokeBorder(color, lineWidth: 1.5).frame(width: 26, height: 26)
                }
                if MeshtasticSummary.isInfrastructure(node.role) {
                    Rectangle().fill(color).frame(width: 9, height: 9).rotationEffect(.degrees(45))
                } else {
                    Circle().fill(color).frame(width: 10, height: 10)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.shortName ?? node.num.short)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text([MeshtasticSummary.path(hops: node.hopsAway, viaMQTT: node.viaMQTT)?.lowercased(),
                      stale ? "stale" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
            .shadow(color: .black.opacity(0.9), radius: 2)
            .fixedSize()
        }
        .padding(.trailing, 4)
        .offset(x: -13)   // the mark's centre, not the pin's edge, sits on the coordinate
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A filter chip on the map (AB `.chip` over the map).
private struct MapChip: View {
    var led: Color? = nil
    let text: String
    var count: Int? = nil
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let led { StatusLED(color: led, on: on, size: 6) }
                Text(text).foregroundStyle(on ? Theme.textPrimary : Theme.textTertiary)
                if let count { Text("\(count)").font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary) }
            }
            .font(Theme.Fonts.footnote.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Theme.surface1.opacity(0.94), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
        }
        .buttonStyle(.rowPress)
    }
}

/// The readout card for the selected pin: bearing, distance, hops, SNR, then actions.
private struct SelectedNodeCard: View {
    let node: NodeInfo
    let from: LatLon?
    let onClose: () -> Void
    let onMessage: () -> Void
    let onTrace: () -> Void
    let onInfo: () -> Void
    let canTrace: Bool

    var body: some View {
        let p = node.position.map { LatLon(lat: $0.latitude, lon: $0.longitude) }
        let bearing = from.flatMap { f in p.map { Geo.bearing(f, $0) } }
        let distance = from.flatMap { f in p.map { Geo.distance(f, $0) } }
        let direct = node.hopsAway == 0 && !node.viaMQTT
        let snr = node.snr.map(Double.init)
        InstrumentPanel {
            HStack(spacing: 12) {
                IconTile(symbol: MeshtasticSummary.symbol(role: node.role, viaMQTT: node.viaMQTT), tint: Theme.meshtastic, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(node.longName ?? node.num.id).font(.system(.headline)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        NetworkTag(.meshtastic)
                    }
                    Text(roleLine).font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 32, height: 32)
                        .overlay(Circle().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(12)
            PanelDivider()
            ReadoutRow {
                ReadoutCell("Bearing", value: bearing.map { String(format: "%03.0f", $0) } ?? "—", unit: bearing == nil ? nil : "°",
                            sub: bearing.map(Geo.compass) ?? "no fix")
                CellDivider()
                ReadoutCell("Dist", value: distance.map { $0 < 1000 ? "\(Int($0.rounded()))" : String(format: "%.1f", $0 / 1000) } ?? "—",
                            unit: distance.map { $0 < 1000 ? "m" : "km" }, sub: "straight line")
                CellDivider()
                ReadoutCell("Hops", value: node.viaMQTT ? "—" : node.hopsAway.map(String.init) ?? "—",
                            sub: node.viaMQTT ? "internet" : node.hopsAway == 0 ? "direct" : "relayed")
                CellDivider()
                ReadoutCell("SNR", value: snr.map { MeshtasticSummary.signed($0) } ?? "—") {
                    if direct, let snr {
                        HStack(spacing: 5) {
                            SegmentMeter(lit: SignalGrade.bars(snr: snr, rssi: nil), of: 5, tint: Theme.meshtastic, size: .xs)
                            Text(SignalGrade.grade(snr: snr, rssi: nil).word).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            PanelDivider()
            Text([node.num.id, node.hardware, node.lastHeard.map { "heard " + DenFormat.ago($0) + " ago" }].compactMap { $0 }
                    .joined(separator: " · "))
                .font(Theme.Fonts.raw)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            HStack(spacing: 8) {
                Button(action: onMessage) { Label("Message", systemImage: "bubble.left") }
                    .buttonStyle(.field(.primary, .regular))
                Button(action: onTrace) { Label("Trace", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                    .buttonStyle(.field(.secondary, .regular))
                    .disabled(!canTrace)
                Button(action: onInfo) { Image(systemName: "info.circle") }
                    .buttonStyle(.field(.secondary, .small))
                    .frame(width: 52)
                    .accessibilityLabel("Node details")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(Theme.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
    }

    private var roleLine: String {
        MeshtasticSummary.isInfrastructure(node.role) ? "Relays messages for everyone" : "A person you can message"
    }
}

/// A glowing node marker on a map.
struct MapDot: View {
    let color: Color
    var size: CGFloat = 13

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
            .glow(color, radius: 6, opacity: 0.8)
    }
}
