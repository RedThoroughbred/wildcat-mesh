import SwiftUI

/// The mesh's text traffic as the Den heard it, and sending through the Den.
struct DenChatView: View {
    @Environment(DenStore.self) private var den
    @State private var channel: Int? = nil

    private var messages: [Den.ChatMessage] {
        den.chat.filter { channel == nil || $0.channel == channel }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty {
                        EmptyState(symbol: "bubble.left.and.bubble.right", title: "Quiet so far",
                                   text: "Messages the Den hears on the mesh this week show up here.")
                            .padding(.top, 40)
                    }
                    ForEach(messages) { m in
                        Bubble(message: m, channelName: den.channelName(m.channel),
                               toName: m.broadcast == true ? nil : den.node(m.to)?.name ?? m.to)
                            .id(m.id)
                    }
                }
                .padding(.horizontal, Theme.Space.edge)
                .padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .onAppear { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            }
        }
        .screen()
        .safeAreaInset(edge: .bottom, spacing: 0) { ComposeBar(channel: channel ?? 0) }
        .navigationTitle("Den messages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("All channels") { channel = nil }
                    ForEach(den.channels) { c in Button("\(c.i) · \(c.n)") { channel = c.i } }
                } label: {
                    Label(channel.map { den.channelName($0) } ?? "All", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .refreshable { await den.refresh() }
    }
}

/// A Den message as a chat line (the Den listens on Meshtastic).
private struct Bubble: View {
    let message: Den.ChatMessage
    let channelName: String
    let toName: String?

    var body: some View {
        var l = ChatLine(id: UUID(), network: .meshtastic, time: message.date, text: message.text ?? "")
        l.mine = message.mine == true
        l.sender = l.mine ? nil : (message.short_name ?? message.sender_id ?? "?")
        l.senderID = l.mine ? nil : message.sender_id
        l.context = toName.map { "→ \($0)" } ?? "#\(channelName)"
        l.snr = message.snr
        l.rssi = message.rssi
        l.status = l.mine ? .sent : .received
        l.radioName = "the Den"
        return MessageBubble(line: l)
    }
}

/// Type and send a broadcast on `channel` through the Den's radio.
private struct ComposeBar: View {
    @Environment(DenStore.self) private var den
    let channel: Int
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        ChatComposer(network: .meshtastic, target: den.channelName(channel), through: "the Den's radio",
                     text: $text, limit: 200, error: error, busy: sending) {
            Task { await send() }
        }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await den.send(text.trimmingCharacters(in: .whitespacesAndNewlines), channel: channel)
            Haptics.thud()
            text = ""
            error = nil
        } catch {
            Haptics.error()
            self.error = DenStore.describe(error)
        }
    }
}

/// A direct message to one node, through the Den.
struct DenComposeSheet: View {
    @Environment(DenStore.self) private var den
    @Environment(\.dismiss) private var dismiss
    let to: String
    let toName: String
    @State private var text = ""
    @State private var channel = 0
    @State private var error: String?
    @State private var sending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Message", text: $text, axis: .vertical).lineLimit(2...6)
                    Picker("Channel", selection: $channel) {
                        ForEach(den.channels) { c in Text("\(c.i) · \(c.n)").tag(c.i) }
                    }
                } footer: {
                    Text("\(text.utf8.count)/200 bytes. Sent as a direct message by the Den's radio.")
                }
                .fieldSection()
                if let error {
                    Section { Notice(text: error, color: Theme.hot) }.fieldSection()
                }
            }
            .fieldForm()
            .navigationTitle("To \(toName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task {
                            sending = true
                            defer { sending = false }
                            do {
                                try await den.send(text, to: to, channel: channel)
                                dismiss()
                            } catch {
                                self.error = DenStore.describe(error)
                            }
                        }
                    }
                    .disabled(text.isEmpty || text.utf8.count > 200 || sending)
                }
            }
        }
        .presentationBackground(Theme.bg)
    }
}
