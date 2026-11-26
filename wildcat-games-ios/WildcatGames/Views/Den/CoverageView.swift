import MapKit
import SwiftUI

/// Where the mesh reaches: your walks (uplink, downlink, dead spots) and the
/// Den's own passive coverage.
struct CoverageView: View {
    @Environment(DenStore.self) private var den
    @Environment(WalkRecorder.self) private var walker
    @Environment(Radio.self) private var radio
    @State private var showWalks = true
    @State private var showDen = true
    @State private var channel: Int?
    @State private var message: String?
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        VStack(spacing: 0) {
            map
            controls
        }
        .screen()
        .navigationTitle("Coverage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await den.loadCoverage() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { WalksList() } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("Saved walks")
            }
        }
    }

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()
            if showDen {
                ForEach(Array(den.coverage.enumerated()), id: \.offset) { _, p in
                    Annotation("", coordinate: .init(latitude: p.lat!, longitude: p.lon!)) {
                        Circle().fill(CoverageColor.snr(p.snr).opacity(0.5)).frame(width: 7, height: 7)
                    }
                }
            }
            if showWalks {
                ForEach(allPoints) { p in
                    Annotation("", coordinate: .init(latitude: p.latitude, longitude: p.longitude)) {
                        CoverageDot(point: p)
                    }
                }
            }
            if let d = den.denNode?.position, let la = d.lat, let lo = d.lon {
                Annotation("Den", coordinate: .init(latitude: la, longitude: lo)) {
                    Image(systemName: "house.lodge").font(.system(size: 13)).foregroundStyle(Theme.ok).padding(6)
                        .background(Theme.bg, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.ok.opacity(0.4), lineWidth: 1))
                }
            }
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton() }
        .overlay(alignment: .topLeading) { legend.padding(10) }
    }

    private var allPoints: [CoveragePoint] {
        (walker.walk?.points ?? []) + walker.walks.flatMap(\.points)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                LayerToggle(title: "My walks", symbol: "figure.walk", isOn: $showWalks)
                LayerToggle(title: "Den heard", symbol: "house.lodge", isOn: $showDen)
            }
            HStack(spacing: 8) {
                LegendDot(color: Theme.ok, label: "strong")
                LegendDot(color: Theme.textPrimary, label: "ok")
                LegendDot(color: Theme.alert, label: "weak")
                LegendDot(color: .black, label: "dead", ring: true)
            }
            .font(Theme.Fonts.labelSmall)
        }
        .padding(8)
        .background(Theme.surface1.opacity(0.92), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    @ViewBuilder private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let w = walker.walk {
                ModuleHeader(1, "Walk", detail: "live")
                ReadoutRow {
                    ReadoutCell("Den heard", value: "\(w.heard)", tint: Theme.ok)
                    CellDivider()
                    ReadoutCell("Dead", value: "\(w.missed)", tint: w.missed > 0 ? Theme.alert : Theme.textPrimary)
                    CellDivider()
                    ReadoutCell("Heard Den", value: "\(w.downlinks)")
                    CellDivider()
                    let last = w.points.last(where: { $0.kind == .uplink })?.snr
                    ReadoutCell("Last", value: last.map { MeshtasticSummary.signed($0) } ?? "—", unit: last == nil ? nil : "dB")
                }
                .instrumentPanel()
                if let p = walker.problem { Notice(text: p) }
                if let b = walker.lastBeacon {
                    HStack(spacing: 8) {
                        StatusPill(text: "Beacon every \(Int(walker.beaconInterval / 60)) min", color: Theme.ok, live: true)
                        Text("last \(b.formatted(date: .omitted, time: .standard))")
                            .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                    }
                }
                Button(role: .destructive) { walker.stop() } label: {
                    Label("Stop walk", systemImage: "stop")
                }
                .buttonStyle(.fieldDestructive)
            } else {
                ModuleHeader(1, "Coverage walk")
                Text("Carry your node, walk or drive. Every \(Int(walker.beaconInterval / 60)) minutes your node sends a beacon with no location in it. The Den reports whether it heard it, and this phone pins the answer to where you were. Keep Wildcat open: logging pauses when the phone locks.")
                    .font(Theme.Fonts.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !radio.isReady || radio.source != .bluetooth {
                    NeedsRadioNotice(.meshtastic, why: "It sends the beacons the Den listens for.")
                }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        CardLabel("Channel")
                        Picker("Channel", selection: channelBinding) {
                            ForEach(channelChoices, id: \.index) { c in Text(c.label).tag(c.index) }
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fieldInput()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        CardLabel("Every")
                        // Five minutes at the fastest: Meshtastic's smart-position floor while moving.
                        FieldSegmented(options: [(300.0, "5 min"), (600.0, "10 min"), (900.0, "15 min")], selection: Bindable(walker).beaconInterval)
                    }
                }
                if radio.isReady, !channelChoices.isEmpty, channelBinding.wrappedValue == 0 {
                    Notice(text: "Beacons on your primary channel reach everyone on it. A private channel the Den also has is kinder.")
                }
                let access = LocationAccess(walker.authorization)
                if access == .denied || access == .restricted {
                    LocationNotice(access: access)
                } else if let message {
                    Notice(text: message, color: Theme.alert)
                }
                Button {
                    message = walker.start(channel: channelBinding.wrappedValue)
                } label: {
                    Label("Start walk", systemImage: "figure.walk")
                }
                .buttonStyle(.fieldPrimary)
            }
        }
        .padding(14)
        .background(Theme.surface1)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    // Channels on my node that the Den also has, private ones first.
    private var channelChoices: [(index: Int, label: String)] {
        let mine = radio.session.channels.values.sorted { $0.index < $1.index }
        let denNames = Set(den.channels.map { $0.n.lowercased() })
        let shared = mine.filter { denNames.contains($0.name.lowercased()) || ($0.index == 0 && $0.name.isEmpty) }
        let list = shared.isEmpty ? mine : shared
        return list.map { ($0.index, $0.name.isEmpty ? "Primary" : $0.name) }
    }

    private var channelBinding: Binding<Int> {
        Binding(get: {
            channel ?? channelChoices.first(where: { $0.index != 0 })?.index ?? 0
        }, set: { channel = $0 })
    }
}

enum CoverageColor {
    static func of(_ q: CoveragePoint.Quality) -> Color {
        switch q {
        case .strong: return Theme.ok
        case .ok: return Theme.textPrimary
        case .weak: return Theme.alert
        case .none: return .black
        }
    }

    static func snr(_ snr: Double?) -> Color {
        guard let snr else { return Theme.textTertiary }
        return snr >= 0 ? Theme.ok : snr <= -10 ? Theme.alert : Theme.textPrimary
    }
}

struct CoverageDot: View {
    let point: CoveragePoint

    var body: some View {
        switch point.kind {
        case .missed:
            Circle().stroke(Color.black, lineWidth: 2.5).background(Circle().fill(Theme.alert.opacity(0.5)))
                .frame(width: 12, height: 12)
        case .downlink:
            Image(systemName: "triangle.fill").font(.system(size: 9)).foregroundStyle(CoverageColor.of(point.quality))
        case .uplink:
            Circle().fill(CoverageColor.of(point.quality)).frame(width: 11, height: 11)
                .overlay(Circle().stroke(Theme.bg, lineWidth: 1.5))
        }
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String
    var ring = false

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(ring ? Theme.alert.opacity(0.5) : color).frame(width: 8, height: 8)
                .overlay(Circle().stroke(ring ? .black : .clear, lineWidth: 1.5))
            Text(label).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Saved walks: open one on its own map, share its CSV, delete it.
struct WalksList: View {
    @Environment(WalkRecorder.self) private var walker

    var body: some View {
        List {
            if walker.walks.isEmpty {
                EmptyState(symbol: "figure.walk", title: "No walks yet", text: "Start one from the coverage map.")
                    .panel()
                    .fieldListRow()
            }
            ForEach(walker.walks) { w in
                NavRow { WalkDetail(walk: w) } label: {
                    HStack(spacing: 12) {
                        IconTile(symbol: "figure.walk", size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(w.name).font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                            Text("\(w.heard) heard · \(w.missed) dead · \(w.downlinks) heard the Den")
                                .font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 6)
                        Chevron()
                    }
                    .panel(.row)
                }
                .fieldListRow()
            }
            .onDelete { idx in idx.map { walker.walks[$0] }.forEach(walker.delete) }
        }
        .fieldList()
        .navigationTitle("Walks")
    }
}

struct WalkDetail: View {
    let walk: CoverageWalk

    var body: some View {
        Map {
            ForEach(walk.points) { p in
                Annotation("", coordinate: .init(latitude: p.latitude, longitude: p.longitude)) { CoverageDot(point: p) }
            }
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .navigationTitle(walk.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: WalkStore.csv(walk), preview: SharePreview("\(walk.name).csv"))
            }
        }
    }
}
