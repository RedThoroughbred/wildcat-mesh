import MapKit
import SwiftUI

/// Your walked hexagons in the fog, and the frontier of the Den's reach.
struct TerritoryView: View {
    @Environment(ExploreModel.self) private var explore
    @Environment(DenStore.self) private var den
    @State private var showFog = true
    @State private var showFrontier = true
    @State private var camera: MapCameraPosition = .region(Self.wholeUS)
    @State private var centred = false

    /// Where the map starts when neither you nor the Den have a position yet.
    static let wholeUS = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.8, longitude: -98.6),
                                            span: MKCoordinateSpan(latitudeDelta: 28, longitudeDelta: 60))

    /// Range rings around the Den, in metres (AB/04: dashed, labelled).
    static let rings: [Double] = [1000, 2000, 3000]

    /// You, else the Den, else your first walk.
    private var centre: LatLon? {
        explore.lastKnown ?? den.denPosition
            ?? explore.allWalkPoints.first.map { LatLon(lat: $0.latitude, lon: $0.longitude) }
    }

    var body: some View {
        let territory = explore.territory
        let grid = territory.grid
        let frontier = explore.frontier
        Map(position: $camera) {
            if showFog { MapPolygon(fog(territory)).foregroundStyle(Color.black.opacity(0.55)) }
            ForEach(Array(territory.tiles.keys), id: \.self) { k in
                if let tile = territory.tiles[k] {
                    MapPolygon(coordinates: grid.corners(k).map(\.coordinate))
                        .foregroundStyle(CoverageColor.of(tile.best).opacity(tile.best == .none ? 0.55 : 0.3))
                        .stroke(CoverageColor.of(tile.best).opacity(0.8), lineWidth: 1)
                }
            }
            if let d = den.denPosition {
                ForEach(Self.rings, id: \.self) { r in
                    MapCircle(center: d.coordinate, radius: r)
                        .foregroundStyle(.clear)
                        .stroke(Theme.textPrimary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    Annotation("", coordinate: Geo.offset(d, distance: r, bearing: 0).coordinate, anchor: .bottom) {
                        Text(Geo.format(r))
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.bottom, 2)
                    }
                }
            }
            if showFrontier, let f = frontier, f.outline.count >= 3 {
                MapPolyline(coordinates: (f.outline + [f.outline[0]]).map(\.coordinate))
                    .stroke(Theme.textPrimary.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            if let d = den.denPosition {
                Annotation("Den", coordinate: d.coordinate) {
                    Image(systemName: "house.lodge")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 26, height: 26)
                        .background(Theme.surface2, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                }
            }
            UserAnnotation()
        }
        .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton() }
        .safeAreaInset(edge: .bottom) { panel(territory, frontier) }
        .navigationTitle("Territory")
        .navigationBarTitleDisplayMode(.inline)
        .task { if den.nodes.isEmpty { await den.refresh() } }
        .onAppear { explore.begin(); centreOnce() }
        .onDisappear { explore.end() }
        .onChange(of: centre) { centreOnce() }
    }

    private func centreOnce() {
        guard !centred, let c = centre else { return }
        centred = true
        camera = .region(MKCoordinateRegion(center: c.coordinate, latitudinalMeters: 6000, longitudinalMeters: 6000))
    }

    /// A dark veil over the area around you with a hole for every walked tile.
    private func fog(_ t: Territory) -> MKPolygon {
        let c = centre ?? LatLon(lat: Self.wholeUS.center.latitude, lon: Self.wholeUS.center.longitude)
        let span = centre == nil ? 40.0 : 4.0   // far past any walk, so the veil's edge stays off screen
        let outer = [LatLon(lat: c.lat - span, lon: c.lon - span), LatLon(lat: c.lat - span, lon: c.lon + span),
                     LatLon(lat: c.lat + span, lon: c.lon + span), LatLon(lat: c.lat + span, lon: c.lon - span)]
            .map(\.coordinate)
        let holes = t.tiles.keys.map { k -> MKPolygon in
            let cs = t.grid.corners(k).map(\.coordinate)
            return MKPolygon(coordinates: cs, count: cs.count)
        }
        return MKPolygon(coordinates: outer, count: outer.count, interiorPolygons: holes)
    }

    private func panel(_ t: Territory, _ f: Frontier?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            InstrumentPanel {
                ReadoutRow {
                    ReadoutCell("Tiles", value: "\(t.explored)")
                    CellDivider()
                    ReadoutCell("Dead", value: "\(t.dead)")
                    CellDivider()
                    ReadoutCell("Farthest", value: f.map { Self.distanceValue($0.farthest) } ?? "--",
                                unit: f.map { $0.farthest < 1000 ? "m" : "km" })
                    CellDivider()
                    ReadoutCell("Sides", value: "\(f?.reach.count ?? 0)", unit: "/16") {
                        SegmentMeter(lit: f?.reach.count ?? 0, of: 16, size: .xs)
                    }
                }
            }
            LocationNotice(access: explore.access) { explore.askLocation() }
            if let d = den.denPosition {
                MetaLine("\(Int(t.explored(within: 3000, of: d) * 100))% of the land within 3 km of the Den explored")
            }
            HStack(spacing: 8) {
                LayerToggle(title: "Fog", symbol: "cloud.fog", isOn: $showFog)
                LayerToggle(title: "Frontier", symbol: "scope", isOn: $showFrontier)
                Spacer()
            }
        }
        .padding(Theme.Space.edge)
        .padding(.top, -2)
        .background(Theme.bg.opacity(0.96))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    /// "850" (m) or "2.4" (km), the unit shown separately.
    static func distanceValue(_ metres: Double) -> String {
        metres < 1000 ? "\(Int(metres.rounded()))" : String(format: "%.1f", metres / 1000)
    }
}

/// A map layer switch: a neutral chip, white when on (AB selected pill).
struct LayerToggle: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            Haptics.selection()
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title).font(Theme.Fonts.footnote.weight(.medium))
            }
            .foregroundStyle(isOn ? Theme.onAccent : Theme.textSecondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(isOn ? Theme.accent : Theme.surface2, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : Theme.hairlineStrong, lineWidth: 1))
        }
        .buttonStyle(.rowPress)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityLabel("\(title) layer")
    }
}
