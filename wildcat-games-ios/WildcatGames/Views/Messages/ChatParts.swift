import SwiftUI
import WildcatRadioCore

// MARK: - Message bubble

/// One message in a chat (AB 03-chat), the same on both networks: sender and
/// short id, the bubble, then a signal meter with a plain line and a raw mono
/// line. Your own messages sit on the right with how they're doing. A bridged
/// line says where it was really said. `expanded` opens the packet under it.
struct MessageBubble: View {
    let line: ChatLine
    var expanded = false
    /// Shown on a failed send.
    var onRetry: (() -> Void)? = nil

    private var origin: MeshNetwork? {
        line.bridged.map { $0.network == .meshtastic ? .meshtastic : .meshcore }
    }

    /// The colour of the network it was said on.
    private var tint: Color { (origin ?? line.network).color }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: line.mine ? 14 : 4, bottomLeadingRadius: 14,
                               bottomTrailingRadius: 14, topTrailingRadius: line.mine ? 4 : 14, style: .continuous)
    }

    var body: some View {
        VStack(alignment: line.mine ? .trailing : .leading, spacing: 0) {
            if let b = line.bridged { bridgeTag(b) }
            if !line.mine { whoLine }
            bubble
                .frame(maxWidth: 318, alignment: line.mine ? .trailing : .leading)
            if !line.reactions.isEmpty { reactions.padding(.top, 5) }
            Group {
                if line.mine { mineMeta } else { receivedMeta }
            }
            .padding(.top, 5)
            .padding(.horizontal, 2)
            if expanded {
                ChatPacketPanel(line: line)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: line.mine ? .trailing : .leading)
    }

    // MARK: Parts

    private func bridgeTag(_ b: BridgeOrigin) -> some View {
        let parts = ["Bridged from \(b.network.title)", b.channel, line.bridgeVia.map { "via \($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return HStack(spacing: 6) {
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 11, weight: .medium))
            Text(parts.joined(separator: " · ").uppercased())
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(tint)
        .padding(.leading, 2)
        .padding(.bottom, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bridged from \(b.network.title)")
    }

    private var whoLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if let sender = line.sender, !sender.isEmpty {
                Text(sender)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if let id = line.senderID {
                Text(id)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(origin?.color ?? Theme.textTertiary)
                    .lineLimit(1)
            }
            if let context = line.context {
                Text(context).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(line.time, format: Self.timeFormat(line.time))
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 4)
    }

    static func timeFormat(_ d: Date) -> Date.FormatStyle {
        Calendar.current.isDateInToday(d) ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let q = line.quote {
                VStack(alignment: .leading, spacing: 1) {
                    Text(q.sender).font(.system(.caption, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    FilteredText(text: q.text, font: .footnote, color: Theme.textSecondary)
                        .lineLimit(2)
                }
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(line.network.color.opacity(0.7)).frame(width: 2)
                }
            }
            if line.filtered {
                FilteredText(text: line.text, font: .system(.subheadline), color: Theme.textPrimary)
            } else {
                Text(line.text).font(.system(.subheadline)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(shape.fill(fill))
        .overlay(shape.strokeBorder(stroke, lineWidth: 1))
        .overlay(alignment: .leading) {
            // A bridged line keeps a thin edge in the colour of the network it came from.
            if origin != nil { Rectangle().fill(tint).frame(width: 2) }
        }
        .clipShape(shape)
    }

    private var fill: Color {
        if expanded { return Theme.surface3 }
        return line.mine ? line.network.color.opacity(0.13) : Theme.surface2
    }

    private var stroke: Color {
        if expanded { return Theme.hairlineStrong }
        return line.mine ? line.network.color.opacity(0.32) : Theme.hairline
    }

    private var reactions: some View {
        HStack(spacing: 4) {
            ForEach(line.reactions, id: \.emoji) { r in
                Text(r.count > 1 ? "\(r.emoji) \(r.count)" : r.emoji)
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.surface1, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            }
        }
    }

    @ViewBuilder
    private var receivedMeta: some View {
        let bars = SignalGrade.bars(snr: line.snr, rssi: line.rssi)
        let plain = ChatMeta.plain(line)
        VStack(alignment: .leading, spacing: 2) {
            if plain != nil || bars > 0 {
                HStack(spacing: 6) {
                    if bars > 0 { SegmentMeter(lit: bars, of: 5, tint: tint, size: .small) }
                    if let plain {
                        Text(plain).font(.footnote).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    }
                }
            }
            if let raw = ChatMeta.raw(line) {
                Text(raw)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var mineMeta: some View {
        let failed = line.status.isFailed
        return VStack(alignment: .trailing, spacing: 4) {
            // Time, raw and status; the time goes first when the line gets too long.
            ViewThatFits(in: .horizontal) {
                mineLine(time: true, failed: failed)
                mineLine(time: false, failed: failed)
            }
            .accessibilityElement(children: .combine)
            if failed, let onRetry {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise").font(.system(.footnote, weight: .semibold))
                }
                .buttonStyle(.field(.secondary, .small))
            }
        }
    }

    private func mineLine(time: Bool, failed: Bool) -> some View {
        let raw = ([time ? Self.clock(line.time) : nil, ChatMeta.sentRaw(line)].compactMap { $0 }).joined(separator: " · ")
        return HStack(spacing: 6) {
            if !raw.isEmpty {
                Text(raw + " ·")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: time, vertical: false)
            }
            if let s = ChatMeta.status(line) {
                Text(s).font(.footnote).foregroundStyle(failed ? Theme.alert : Theme.textSecondary).lineLimit(1)
                    .fixedSize(horizontal: time, vertical: false)
                    .layoutPriority(1)
            }
            StatusGlyph(status: line.status)
        }
    }

    static func clock(_ d: Date) -> String { d.formatted(timeFormat(d)) }
}

/// The small mark after your own message: a clock, one check, two checks (green), or an alert.
struct StatusGlyph: View {
    let status: ChatLine.Status

    var body: some View {
        switch status {
        case .sending, .retrying:
            Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
        case .sent, .awaiting:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
        case .heardBy, .delivered:
            DoubleCheck().foregroundStyle(Theme.ok)
        case .failed, .undelivered:
            Image(systemName: "exclamationmark.circle").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.alert)
        case .received, .unheard:
            EmptyView()
        }
    }
}

/// Two overlapping checks: heard or delivered.
struct DoubleCheck: View {
    var body: some View {
        HStack(spacing: -6) {
            Image(systemName: "checkmark")
            Image(systemName: "checkmark")
        }
        .font(.system(size: 11, weight: .semibold))
        .accessibilityLabel("confirmed")
    }
}

// MARK: - Packet panel

/// The packet under a message (long-press → Show raw packet): a hex dump when
/// "Keep raw packets" was on when it arrived, otherwise the decoded fields and
/// a switch to start keeping them.
struct ChatPacketPanel: View {
    let line: ChatLine
    @AppStorage(MessageStore.keepRawKey) private var keepRaw = false
    @Environment(MeshCoreLink.self) private var meshcore
    @Environment(MessageStore.self) private var messages

    private var detail: String {
        var parts = [line.kind ?? "TEXT"]
        if let s = line.size { parts.append("\(s) B") }
        if let a = line.airtimeMs { parts.append("\(a) ms") }
        return parts.joined(separator: " · ")
    }

    private var fields: [(label: String, value: String)] {
        var f: [(label: String, value: String)] = []
        if let p = line.path { f.append(("Path", p.isEmpty ? "direct" : ChatMeta.path(p, separator: " › "))) }
        else if let h = line.hops { f.append(("Hops", h == 0 ? "direct" : line.hopStart.map { "\(h) of \($0)" } ?? "\(h)")) }
        if let s = line.snr { f.append(("SNR", ChatMeta.number(s) + " dB")) }
        if let r = line.rssi { f.append(("RSSI", ChatMeta.minus("\(r)"))) }
        f.append((line.mine ? "TX" : "RX", line.radioName ?? "this radio"))
        if let id = line.senderID, !line.mine { f.append(("From", id)) }
        if let r = line.relayNode { f.append(("Relay", String(format: "%02x", r & 0xff))) }
        if let hash = line.packetHash { f.append(("Hash", String(hash.prefix(8)))) }
        if let rt = line.roundTripMs { f.append(("Round trip", ChatMeta.duration(ms: rt))) }
        if let heard = line.heardByCount { f.append(("Repeats", "\(heard)")) }
        return f
    }

    /// MeshCore: the path bytes in blue, the header byte bright.
    private var highlights: [ByteHighlight] {
        guard line.network == .meshcore, let raw = line.raw, let p = MeshCorePacket(raw) else { return [] }
        let start = 2 + p.transportCodes.count
        let count = p.path.count * p.hashSize
        return count > 0 ? [ByteHighlight(range: start..<(start + count), color: Theme.meshcore)] : []
    }

    var body: some View {
        if let raw = line.raw, !raw.isEmpty {
            RawPacketView(data: raw, fields: fields, detail: detail, highlights: highlights, emphasis: 0..<1)
        } else {
            decoded
        }
    }

    private var decoded: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                CardLabel("Packet", tint: Theme.textSecondary)
                Text(detail).font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(1)
                Spacer(minLength: 4)
                Text("decoded").font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            PanelDivider()
            let rows = stride(from: 0, to: fields.count, by: 4).map { Array(fields[$0..<min($0 + 4, fields.count)]) }
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                if r > 0 { PanelDivider() }
                ReadoutRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { i, field in
                        if i > 0 { CellDivider() }
                        VStack(alignment: .leading, spacing: 2) {
                            CardLabel(field.label)
                            Text(field.value)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            PanelDivider()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 12))
                Text(keepRaw ? "Keeping raw packets now. Messages that arrive from here on show their bytes."
                             : "The bytes weren't kept. Turn on Keep raw packets to see them for new messages.")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if !keepRaw {
                    Button("Turn on") {
                        keepRaw = true
                        meshcore.keepsRawPackets = true
                        messages.keepsRawPackets = true
                        Haptics.tap()
                    }
                    .buttonStyle(.field(.secondary, .small))
                }
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(10)
        }
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
    }
}

private extension ChatLine {
    var heardByCount: Int? { if case .heardBy(let n) = status { return n } else { return nil } }
}

// MARK: - Header and readouts

/// The chat's title in the nav bar: "# Public" over "● MeshCore · via Wildcat Bag".
struct ChatTitle: View {
    let title: String
    let network: MeshNetwork
    var via: String?
    var connected = true

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Circle().fill(connected ? network.color : Theme.textQuaternary).frame(width: 6, height: 6)
                Text([network.name, via.map { "via \($0)" } ?? (connected ? nil : "not connected")]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A thin row of readouts under the chat title (AB `.strip`): HEARD · MODE · SF / BW …
struct ChatStrip: View {
    let cells: [(label: String, value: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                if i > 0 { CellDivider() }
                VStack(alignment: .leading, spacing: 1) {
                    CardLabel(c.label)
                    Text(c.value)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

// MARK: - Composer

/// The message field (AB `.composer`): which network, chat and radio it goes
/// through, the estimated airtime and bytes, an optional reply, and a white
/// send button.
struct ChatComposer: View {
    let network: MeshNetwork
    /// "Public", "MAYA".
    let target: String
    /// The radio it goes out on.
    var through: String?
    var direct = false
    @Binding var text: String
    /// Bytes allowed in one message.
    var limit = 200
    /// Airtime in ms for the current text, when it can be estimated.
    var airtimeMs: Int?
    /// A second line: where else it goes (the bridge).
    var note: String?
    var error: String?
    var reply: ChatLine.Quote?
    var onCancelReply: (() -> Void)?
    var canSend = true
    var busy = false
    let onSend: () -> Void

    @FocusState private var focused: Bool

    private var bytes: Int { text.utf8.count }
    private var overLimit: Bool { bytes > limit }
    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var sendable: Bool { canSend && !empty && !overLimit && !busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            route
            if let reply {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left").font(.caption).foregroundStyle(Theme.textTertiary)
                    Text("\(reply.sender): \(reply.text)").font(.footnote).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer()
                    Button { onCancelReply?() } label: { Image(systemName: "xmark.circle") }
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityLabel("Cancel reply")
                }
                .padding(.horizontal, 4)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.accent)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(minHeight: 38)
                    .background(Theme.surface1, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .strokeBorder(overLimit ? Theme.alert.opacity(0.6) : Theme.hairlineStrong, lineWidth: 1))
                Button(action: onSend) {
                    Group {
                        if busy { ProgressView().tint(Theme.onAccent) }
                        else { Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)) }
                    }
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.rowPress)
                .disabled(!sendable)
                .opacity(sendable || busy ? 1 : 0.35)
                .accessibilityLabel("Send")
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(Theme.alert).padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.bar)
        .background(Theme.bg.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var route: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(canSend ? network.color : Theme.textQuaternary).frame(width: 6, height: 6)
                // Drops "through …" before it would cut the chat's name.
                ViewThatFits(in: .horizontal) {
                    routeText(through: through)
                    routeText(through: nil)
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 6)
                Text(stats)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(overLimit ? Theme.alert : Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).padding(.leading, 13)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private func routeText(through: String?) -> some View {
        (Text(canSend ? (direct ? "Sending only to " : "Sending to ") : "Can't send to ")
         + Text(target).foregroundStyle(Theme.textPrimary).fontWeight(.semibold)
         + Text(through.map { " through \($0)" } ?? ""))
            .lineLimit(1)
            .fixedSize(horizontal: through != nil, vertical: false)
    }

    private var stats: String {
        var parts: [String] = []
        if let a = airtimeMs, !empty { parts.append("~\(a) ms air") }
        // The byte count only once it starts to matter.
        if bytes * 10 >= limit * 7 || (airtimeMs == nil && !empty) { parts.append("\(bytes)/\(limit) B") }
        return parts.joined(separator: " · ")
    }
}
