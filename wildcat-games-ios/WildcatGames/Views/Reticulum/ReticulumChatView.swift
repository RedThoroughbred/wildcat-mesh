import SwiftUI
import WildcatRadioCore

/// One Reticulum conversation: the messages with their delivery state in plain words, and the
/// composer. Received text is shown through the word filter; a blocked sender has no screen.
struct ReticulumChatView: View {
    let peer: String
    @Bindable var model: ReticulumModel
    @Environment(Safety.self) private var safety
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var safetyAction: SafetyAction?
    @FocusState private var typing: Bool

    private var contact: Reticulum.Contact? { model.book.contact(peer) }
    private var title: String { model.title(for: peer) }

    var body: some View {
        let messages = model.thread(with: peer)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    header
                    if messages.isEmpty {
                        Text("No messages yet.")
                            .font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                            .padding(.top, 24)
                    }
                    ForEach(messages) { m in
                        ReticulumBubble(message: m, text: model.shown(m), masked: m.incoming && safety.masks(m.text))
                            .id(m.id)
                            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contextMenu {
                                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = model.shown(m) }
                                if !m.incoming, m.delivery == .failed {
                                    Button("Send again", systemImage: "arrow.clockwise") { model.send(to: peer, text: m.text) }
                                        .disabled(!canSend)
                                }
                                if m.incoming { SafetyMenuItems(flagged: flagged(m), action: $safetyAction) }
                            }
                    }
                }
                .padding(.horizontal, Theme.Space.edge)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
            .onChange(of: messages.count, initial: true) { _, _ in
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .screen()
        .safetyPrompts($safetyAction)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(title).font(.headline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(model.anyLinkOnline ? ReticulumStyle.color : Theme.textQuaternary).frame(width: 6, height: 6)
                        Text(model.anyLinkOnline ? "Reticulum · beta" : "Reticulum · not running")
                            .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Copy address", systemImage: "doc.on.doc") { UIPasteboard.general.string = peer }
                    Button("Block \(title)", systemImage: "hand.raised", role: .destructive) {
                        safety.block(.reticulum(peer, name: contact?.name))
                        dismiss()
                    }
                    Button("Delete conversation", systemImage: "trash", role: .destructive) {
                        model.removeConversation(with: peer)
                        dismiss()
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("More")
            }
        }
        .tint(ReticulumStyle.color)
        .onAppear { model.openPeer = peer }
        .onDisappear { if model.openPeer == peer { model.openPeer = nil } }
        .onChange(of: safety.hides(reticulum: peer)) { _, blocked in if blocked { dismiss() } }
    }

    /// Who this is, as far as the phone knows.
    private var header: some View {
        VStack(spacing: 5) {
            Text("<\(peer)>")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(heardLine).font(Theme.Fonts.footnote).foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    private var heardLine: String {
        guard let c = contact, let at = c.lastHeard else {
            return "Not heard on air yet. A message can only reach them once their announce has reached this phone."
        }
        let hops = c.hops.map { $0 <= 1 ? "direct" : "\($0) hops away" }
        return (["Last announce \(ReticulumChatFormat.when(at))", hops].compactMap { $0 }).joined(separator: " · ")
            + ". End-to-end encrypted by Reticulum."
    }

    private var canSend: Bool { model.isRunning && model.anyLinkOnline && contact?.needsStamp != true }

    /// Why the composer can't send right now, or a hint, in plain words.
    private var composerNote: (text: String, warn: Bool)? {
        if contact?.needsStamp == true { return (Reticulum.Failure.needsStamp.line, true) }
        if !model.isRunning { return ("Reticulum isn't running. Start it on the Reticulum screen to send.", true) }
        if !model.anyLinkOnline { return (model.radio != nil ? "Waiting for the RNode's radio." : "Waiting for the internet link.", true) }
        if model.lastAnnounce == nil { return ("Announce on the Reticulum screen so their reply can find you.", false) }
        return nil
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note = composerNote {
                Text(note.text).font(Theme.Fonts.footnote).foregroundStyle(note.warn ? Theme.warn : Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .accessibilityIdentifier("reticulum.composerNote")
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($typing)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                    .accessibilityIdentifier("reticulum.message")
                Button {
                    if model.send(to: peer, text: draft) != nil {
                        draft = ""
                        Haptics.tick()
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 36, height: 36)
                        .background(sendable ? Theme.accent : Theme.textQuaternary, in: Circle())
                }
                .disabled(!sendable)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("reticulum.send")
            }
            if draft.utf8.count > ReticulumChatFormat.softLimit {
                Text("\(draft.utf8.count) bytes: a long message takes many packets and a long time over LoRa.")
                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, Theme.Space.edge)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Theme.bg)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var sendable: Bool {
        canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.utf8.count <= ReticulumChatFormat.hardLimit
    }

    private func flagged(_ m: Reticulum.Message) -> Flagged {
        Flagged(sender: .reticulum(peer, name: contact?.name ?? Reticulum.shortAddress(peer)), network: "Reticulum",
                place: "direct message", text: m.text, time: m.at)
    }
}

/// One message: the bubble, then the time and, for your own, how it is doing. A failure says why.
struct ReticulumBubble: View {
    let message: Reticulum.Message
    let text: String
    var masked = false

    private var mine: Bool { !message.incoming }
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: mine ? 14 : 4, bottomLeadingRadius: 14,
                               bottomTrailingRadius: 14, topTrailingRadius: mine ? 4 : 14, style: .continuous)
    }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 5) {
            Text(text)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(mine ? ReticulumStyle.color.opacity(0.16) : Theme.surface2, in: shape)
                .overlay(shape.strokeBorder(mine ? ReticulumStyle.color.opacity(0.35) : Theme.hairlineStrong, lineWidth: 1))
                .frame(maxWidth: 318, alignment: mine ? .trailing : .leading)
            HStack(spacing: 5) {
                if mine {
                    Image(systemName: ReticulumChatFormat.glyph(message.delivery))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ReticulumChatFormat.color(message.delivery))
                    Text(message.delivery.word.uppercased())
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(0.5)
                        .foregroundStyle(ReticulumChatFormat.color(message.delivery))
                }
                Text(message.at.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary)
                if masked { Text("· filtered").font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary) }
            }
            .padding(.horizontal, 2)
            if let why = note {
                Text(why)
                    .font(Theme.Fonts.footnote).foregroundStyle(message.delivery == .failed ? Theme.alert : Theme.warn)
                    .multilineTextAlignment(mine ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 318, alignment: mine ? .trailing : .leading)
                    .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }

    private var note: String? {
        if mine { return message.delivery == .failed ? (message.failure ?? .noAnswer).line : nil }
        return message.trust?.note
    }
}

enum ReticulumChatFormat {
    /// Past this a message stops fitting in one LoRa packet and needs a link and several packets.
    static let softLimit = 280
    static let hardLimit = 2000

    static func glyph(_ d: Reticulum.Delivery) -> String {
        switch d {
        case .queued: return "clock"
        case .findingPath: return "point.topleft.down.to.point.bottomright.curvepath"
        case .sending: return "arrow.up.circle"
        case .sent: return "checkmark"
        case .delivered: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        case .received: return "arrow.down"
        }
    }

    static func color(_ d: Reticulum.Delivery) -> Color {
        switch d {
        case .delivered: return Theme.ok
        case .failed: return Theme.alert
        default: return Theme.textTertiary
        }
    }

    /// "14:02" today, "Tue 14:02" this week, else the date.
    static func when(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if now.timeIntervalSince(date) < 6 * 86_400, date < now {
            return date.formatted(.dateTime.weekday(.abbreviated)) + " " + date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
