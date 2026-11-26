import MapKit
import SwiftUI

/// Nodes with a position: amber (Meshtastic) when the Den hears them over the air, grey via the internet.
struct DenMapView: View {
    @Environment(DenStore.self) private var den
    @State private var selected: String?
    @State private var rfOnly = false

    private var placed: [Den.Node] { den.nodes.filter { $0.hasPosition && (!rfOnly || $0.isRF) } }

    var body: some View {
        Map(selection: $selected) {
            ForEach(placed) { n in
                let p = n.position!
                Annotation(n.name, coordinate: CLLocationCoordinate2D(latitude: p.lat!, longitude: p.lon!)) {
                    MapDot(color: n.id == den.myID ? Theme.ok : n.isRF ? Theme.meshtastic : Theme.textTertiary,
                           size: n.id == den.myID ? 17 : 12)
                }
                .tag(n.id)
            }
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if let id = selected, let n = den.node(id) {
                    NavRow { DenNodeDetail(node: n) } label: {
                        HStack {
                            DenNodeRow(node: n, signal: den.signal?.nodes.first { $0.id == id })
                            Chevron()
                        }
                        .panel(.row)
                    }
                }
                FieldSegmented(options: [(false, "All \(den.nodes.filter(\.hasPosition).count)"), (true, "Over RF")], selection: $rfOnly)
            }
            .padding(12)
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
    }
}
