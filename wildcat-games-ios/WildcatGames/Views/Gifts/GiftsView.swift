import MapKit
import SwiftUI
import WildcatRadioCore

/// Geo Gifts: messages that only open at a place.
struct GiftsView: View {
    @Environment(GiftStore.self) private var gifts
    @State private var tab = 0
    @State private var leaving = false
    @State private var pasteError = false

    var body: some View {
        List {
            FieldSegmented(options: [(0, "For me (\(gifts.received.count))"), (1, "I left (\(gifts.sent.count))")], selection: $tab)
                .fieldListRow()
                .padding(.bottom, 4)
            if gifts.access == .denied || gifts.access == .restricted {
                LocationNotice(access: gifts.access).fieldListRow()
            }
            if tab == 0 {
                if gifts.received.isEmpty {
                    EmptyState(symbol: "gift", title: "No gifts yet",
                               text: "When someone leaves you a gift over the mesh, or sends you a gift link, it shows up here, locked until you stand on the spot.")
                        .panel()
                        .fieldListRow()
                }
                ForEach(gifts.received) { r in
                    ListNavRow { ReceivedGiftView(id: r.id) } label: {
                        ReceivedRow(r: r, here: gifts.here).panel(.row)
                    }
                    .fieldListRow()
                }
                .onDelete { idx in idx.map { gifts.received[$0] }.forEach(gifts.deleteReceived) }
                Button {
                    pasteError = !gifts.importLink(UIPasteboard.general.string ?? "")
                } label: {
                    Label("Open a gift link from the clipboard", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.fieldSecondary)
                .fieldListRow()
                .padding(.top, 6)
            } else {
                if gifts.sent.isEmpty {
                    EmptyState(symbol: "gift", title: "Leave your first gift",
                               text: "Stand somewhere meaningful, write a message, and send it. It only opens when they stand there too.",
                               actionTitle: "Leave a gift", action: { leaving = true })
                        .panel()
                        .fieldListRow()
                }
                ForEach(gifts.sent) { s in
                    ListNavRow { SentGiftView(gift: s) } label: {
                        SentRow(s: s).panel(.row)
                    }
                    .fieldListRow()
                }
                .onDelete { idx in idx.map { gifts.sent[$0] }.forEach(gifts.deleteSent) }
            }
        }
        .fieldList()
        .navigationTitle("Geo Gifts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { leaving = true } label: { Label("Leave a gift", systemImage: "gift") }
            }
        }
        .sheet(isPresented: $leaving) { LeaveGiftView() }
        .alert("No gift link on the clipboard", isPresented: $pasteError) { Button("OK") {} }
        .onAppear { gifts.startWatching() }
        .onDisappear { gifts.stopWatching() }
        .overlay { GiftReveal() }
    }
}

private struct ReceivedRow: View {
    let r: GiftStore.Received
    let here: LatLon?

    var body: some View {
        let opened = r.opened != nil
        HStack(spacing: 12) {
            IconTile(symbol: opened ? "gift" : "lock", tint: opened ? Theme.ok : nil, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.gift?.teaser.isEmpty == false ? "\u{201C}\(r.gift!.teaser)\u{201D}" : "A gift")
                    .font(Theme.Fonts.heading)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("from \(r.fromName ?? "a link") · \(distanceText)")
                    .font(Theme.Fonts.dataSmall)
                    .foregroundStyle(opened ? Theme.ok : Theme.textSecondary)
            }
            Spacer(minLength: 6)
            Chevron()
        }
        .accessibilityElement(children: .combine)
    }

    private var distanceText: String {
        if r.opened != nil { return "opened" }
        guard let g = r.gift, let here else { return "locked" }
        if g.hintRadius == 0 { return "\(Geo.format(Geo.distance(here, g.hintCenter))) away" }
        let d = Geo.distance(here, g.hintCenter) - Double(g.hintRadius)
        return d <= 0 ? "you're in the area" : "area \(Geo.format(d)) away"
    }
}

private struct SentRow: View {
    let s: GiftStore.Sent

    var body: some View {
        let opened = s.opened != nil
        HStack(spacing: 12) {
            IconTile(symbol: opened ? "checkmark.seal" : "hourglass", tint: opened ? Theme.ok : nil, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.teaser.isEmpty ? "(no teaser)" : "\u{201C}\(s.teaser)\u{201D}")
                    .font(Theme.Fonts.heading)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(opened ? "Opened by \(s.openedBy ?? "someone") · \(s.opened!.formatted(date: .abbreviated, time: .shortened))"
                     : "Waiting · left \(s.sent.formatted(date: .abbreviated, time: .omitted))")
                    .font(Theme.Fonts.dataSmall)
                    .foregroundStyle(opened ? Theme.ok : Theme.textSecondary)
            }
            Spacer(minLength: 6)
            Chevron()
        }
        .accessibilityElement(children: .combine)
    }
}

/// A received gift: locked (map of the hint area) or opened (the message).
struct ReceivedGiftView: View {
    @Environment(GiftStore.self) private var gifts
    let id: UInt32

    var body: some View {
        if let r = gifts.received.first(where: { $0.id == id }), let g = r.gift {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let message = r.message {
                        GiftCard(message: message, from: r.fromName, teaser: g.teaser)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                IconTile(symbol: "lock", size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    CardLabel("Locked")
                                    Text("From \(r.fromName ?? "a gift link")").font(Theme.Fonts.heading).foregroundStyle(Theme.textPrimary)
                                }
                            }
                            if !g.teaser.isEmpty {
                                Text("\u{201C}\(g.teaser)\u{201D}").font(.system(.title3, design: .serif).italic()).foregroundStyle(Theme.textPrimary)
                            }
                            Text("It opens by itself when you're standing on the spot (\(g.precision.title.lowercased())).")
                                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panel()
                        if let here = gifts.here {
                            let d = Geo.distance(here, g.hintCenter)
                            let b = Geo.bearing(here, g.hintCenter)
                            let toEdge = max(0, d - Double(g.hintRadius))
                            ModuleHeader(1, g.hintRadius == 0 ? "To the spot" : "To the area")
                                .padding(.top, 6)
                            FoxInstrumentRow {
                                FoxBearingRadar(bearing: b, distance: toEdge, live: false)
                            } readouts: {
                                FoxReadoutGrid(cells: [
                                    FoxCell(label: "Distance", value: Self.distanceValue(toEdge), unit: toEdge < 1000 ? "m" : "km",
                                            sub: g.hintRadius == 0 ? "straight line" : "to the edge"),
                                    FoxCell(label: "Bearing", value: FoxReadout.degrees(b), sub: Geo.compass(b)),
                                    FoxCell(label: "Area", value: g.hintRadius == 0 ? "--" : Self.distanceValue(Double(g.hintRadius)),
                                            unit: g.hintRadius == 0 ? nil : (g.hintRadius < 1000 ? "m" : "km"),
                                            sub: g.hintRadius == 0 ? "exact spot" : "radius"),
                                    FoxCell(label: "Opens", value: "\(Int(g.precision.metres))", unit: "m", sub: "from the spot"),
                                ]) {
                                    FoxWideCell(label: "Status",
                                                text: g.hintRadius > 0 && d <= Double(g.hintRadius)
                                                    ? "You're inside the area. Search it!"
                                                    : "Head \(FoxReadout.direction(b)).")
                                }
                            }
                        }
                    }
                    ModuleHeader(nil, "Map")
                        .padding(.top, 6)
                    Map(initialPosition: .region(MKCoordinateRegion(center: g.hintCenter.coordinate,
                                                                    latitudinalMeters: max(600, Double(g.hintRadius) * 3),
                                                                    longitudinalMeters: max(600, Double(g.hintRadius) * 3)))) {
                        if g.hintRadius > 0 {
                            MapCircle(center: g.hintCenter.coordinate, radius: CLLocationDistance(g.hintRadius))
                                .foregroundStyle(Theme.textPrimary.opacity(0.06))
                                .stroke(Theme.textPrimary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        } else {
                            Annotation("Gift", coordinate: g.hintCenter.coordinate) { GiftPin() }
                        }
                        UserAnnotation()
                    }
                    .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                }
                .padding(Theme.Space.edge)
            }
            .screen()
            .navigationTitle(r.message == nil ? "Locked gift" : "Gift")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { gifts.startWatching() }
            .onDisappear { gifts.stopWatching() }
            .overlay { GiftReveal() }
        }
    }

    /// "850" (m) or "2.4" (km), the unit shown separately.
    static func distanceValue(_ metres: Double) -> String {
        metres < 1000 ? "\(Int(metres.rounded()))" : String(format: "%.1f", metres / 1000)
    }
}

/// A gift on a map: a white disc with an outlined gift, dark rim (gifts
/// belong to no one network, so no network colour).
struct GiftPin: View {
    var body: some View {
        Image(systemName: "gift")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.onAccent)
            .frame(width: 26, height: 26)
            .background(Theme.accent, in: Circle())
            .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
            .accessibilityHidden(true)
    }
}

/// The message itself, like a card left on a table.
struct GiftCard: View {
    let message: String
    let from: String?
    let teaser: String

    var body: some View {
        VStack(spacing: 14) {
            IconTile(symbol: "gift", size: 44)
            if !teaser.isEmpty { CardLabel(teaser) }
            Text(message)
                .font(.system(.title3, design: .serif).italic())
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Theme.hairlineStrong).frame(width: 48, height: 1)
            Text("— \(from ?? "someone")").font(Theme.Fonts.data).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .panel(.hero)
    }
}

/// The moment a gift opens: a burst, the card, and a button to keep it.
struct GiftReveal: View {
    @Environment(GiftStore.self) private var gifts
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var burst = 0

    var body: some View {
        if let r = gifts.justOpened, let message = r.message {
            ZStack {
                Color.black.opacity(0.78).ignoresSafeArea().onTapGesture { gifts.justOpened = nil }
                VStack(spacing: 18) {
                    Text("YOU FOUND IT")
                        .font(.system(.largeTitle, design: .monospaced, weight: .light))
                        .foregroundStyle(Theme.ok)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    GiftCard(message: message, from: r.fromName, teaser: r.gift?.teaser ?? "")
                    Button("Keep it") { gifts.justOpened = nil }
                        .buttonStyle(.fieldPrimary)
                }
                .padding(24)
                .scaleEffect(shown || reduceMotion ? 1 : 0.85)
                .opacity(shown ? 1 : 0)
                CelebrationBurst(trigger: burst, colors: [Theme.ok, Theme.textPrimary, Theme.textSecondary], count: 90)
            }
            .sensoryFeedback(.success, trigger: r.id)
            .onAppear {
                Haptics.prepare()
                withAnimation(Theme.Motion.respecting(reduceMotion, Theme.Motion.pop)) { shown = true }
                burst += 1
            }
            .onDisappear { shown = false }
            .transition(.opacity)
        }
    }
}

struct SentGiftView: View {
    let gift: GiftStore.Sent
    @State private var showQR = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.stack) {
                GiftCard(message: gift.message, from: "you", teaser: gift.teaser)
                HStack(spacing: 8) {
                    StatusLED(color: Theme.ok, on: gift.opened != nil, size: 6)
                    Text(gift.opened != nil ? "Opened by \(gift.openedBy ?? "someone")" : "Not opened yet")
                }
                .font(Theme.Fonts.footnote)
                .foregroundStyle(Theme.textSecondary)
                Map(initialPosition: .region(MKCoordinateRegion(center: gift.spot.coordinate, latitudinalMeters: 600, longitudinalMeters: 600))) {
                    if let g = gift.gift, g.hintRadius > 0 {
                        MapCircle(center: g.hintCenter.coordinate, radius: CLLocationDistance(g.hintRadius))
                            .foregroundStyle(Theme.textPrimary.opacity(0.06))
                            .stroke(Theme.textPrimary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    Annotation("Spot", coordinate: gift.spot.coordinate) { GiftPin() }
                }
                .mapStyle(.standard(emphasis: .muted, pointsOfInterest: .excludingAll))
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                if let g = gift.gift {
                    let link = GiftCodec.link(g)
                    ShareLink(item: link, message: Text("I left you something. Open it in Wildcat when you're there.")) {
                        Label("Send as a link", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.fieldPrimary)
                    Button { withAnimation(Theme.Motion.settle) { showQR.toggle() } } label: {
                        Label(showQR ? "Hide QR code" : "Show QR code", systemImage: "qrcode")
                    }
                    .buttonStyle(.fieldSecondary)
                    if showQR { QRImage(text: link).transition(.opacity) }
                }
            }
            .padding(Theme.Space.edge)
            .padding(.bottom, Theme.Space.xl)
        }
        .screen()
        .navigationTitle("Your gift")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A card row in a `List` that pushes a destination without the system's
/// own disclosure chevron (the card draws its own, inside the panel).
private struct ListNavRow<Destination: View, Label: View>: View {
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label

    var body: some View {
        label()
            .background {
                NavigationLink(destination: destination) { EmptyView() }
                    .opacity(0)
            }
    }
}
