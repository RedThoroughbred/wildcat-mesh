import Foundation
import Observation
import WildcatRadioCore

/// Applies settings to the player's own node: fetches a session passkey,
/// wraps the changes in begin/commit edit, then refreshes (or waits for the
/// reboot some changes cause).
@MainActor
@Observable
final class NodeAdmin {
    enum Change {
        case owner(Data)
        case config(ConfigSection, Data)
        case module(ModuleSection, Data)
        case channel(index: Int, settings: Data?, role: ChannelInfo.Role)
        case reboot
        case favorite(NodeNum, Bool)
        case ignore(NodeNum, Bool)
        case remove(NodeNum)
        case fixedPosition(Coordinate, altitude: Int?)
        case clearFixedPosition

        /// Radio and role changes make the firmware restart by itself.
        var restarts: Bool {
            switch self {
            case .config(let s, _): return s == .lora || s == .device || s == .bluetooth
            // Module changes may restart the node too: keep them last.
            case .module: return true
            case .reboot: return true
            default: return false
            }
        }
    }

    enum Status: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private let radio: Radio

    init(radio: Radio) { self.radio = radio }

    var isWorking: Bool { if case .working = status { return true } else { return false } }

    /// Gap between admin packets: small nRF52 boards drop back-to-back ones.
    static let spacing: Duration = .milliseconds(900)

    func apply(_ changes: [Change], summary: String) async {
        // Channels and names first, in their own transaction; changes that
        // restart the node (radio, role, reboot) go in a second one, last.
        let first = changes.filter { !$0.restarts }
        let last = changes.filter(\.restarts)
        if !first.isEmpty && !last.isEmpty {
            await transaction(first, summary: summary, final: false)
            if case .failed = status { return }
            try? await Task.sleep(for: .seconds(2))
            await transaction(last, summary: summary, final: true)
        } else {
            await transaction(changes, summary: summary, final: true)
        }
    }

    private func transaction(_ changes: [Change], summary: String, final: Bool) async {
        guard radio.source == .bluetooth, let link = radio.link, link.state.isReady,
              let me = radio.session.myNode else {
            status = .failed("Connect your node first.")
            return
        }
        status = .working("Signing in to the node…")
        guard let key = await passkey(link: link, me: me) else {
            status = .failed("The node didn't answer. Try again, or reconnect it.")
            return
        }
        status = .working("Sending \(summary.lowercased())…")
        link.send(toRadio: Admin.beginEdit(node: me, passkey: key, id: MeshCodec.newPacketID()))
        for c in changes {
            try? await Task.sleep(for: Self.spacing)
            let id = MeshCodec.newPacketID()
            switch c {
            case .owner(let u):
                link.send(toRadio: Admin.setOwner(u, node: me, passkey: key, id: id))
            case .config(let s, let inner):
                link.send(toRadio: Admin.setConfig(s, inner, node: me, passkey: key, id: id))
                link.updateSession { $0.applyLocally(s, inner) }
            case .module(let s, let inner):
                link.send(toRadio: Admin.setModuleConfig(s, inner, node: me, passkey: key, id: id))
                link.updateSession { $0.applyLocally(module: s, inner) }
            case .channel(let index, let settings, let role):
                link.send(toRadio: Admin.setChannel(index: index, settings: settings, role: role, node: me, passkey: key, id: id))
                let name = settings.map { ChannelSettings(raw: $0).name } ?? ""
                link.updateSession { $0.applyLocally(channel: ChannelInfo(index: index, name: name, role: role, settings: settings)) }
            case .reboot:
                break
            case .favorite(let n, let on):
                link.send(toRadio: Admin.setFavorite(n, on, me: me, passkey: key, id: id))
                link.updateSession { $0.setFlags(n, favorite: on) }
            case .ignore(let n, let on):
                link.send(toRadio: Admin.setIgnored(n, on, me: me, passkey: key, id: id))
                link.updateSession { $0.setFlags(n, ignored: on) }
            case .fixedPosition(let c, let alt):
                link.send(toRadio: Admin.setFixedPosition(c, altitude: alt, time: Date(), me: me, passkey: key, id: id))
            case .clearFixedPosition:
                link.send(toRadio: Admin.removeFixedPosition(me: me, passkey: key, id: id))
            case .remove(let n):
                link.send(toRadio: Admin.removeNode(n, me: me, passkey: key, id: id))
                link.updateSession { $0.setFlags(n, remove: true) }
            }
        }
        try? await Task.sleep(for: Self.spacing)
        link.send(toRadio: Admin.commitEdit(node: me, passkey: key, id: MeshCodec.newPacketID()))
        guard final else {
            try? await Task.sleep(for: Self.spacing)
            return
        }
        if changes.contains(where: \.restarts) {
            if changes.contains(where: { if case .reboot = $0 { return true } else { return false } }) {
                try? await Task.sleep(for: .milliseconds(300))
                link.send(toRadio: Admin.reboot(node: me, seconds: 3, passkey: key, id: MeshCodec.newPacketID()))
            }
            status = .done("\(summary) saved. The node restarts to apply it: reconnect in about 20 seconds.")
        } else if changes.allSatisfy({ c in
            switch c { case .favorite, .ignore, .remove: return true; default: return false }
        }) {
            status = .done("\(summary) saved.")
        } else {
            try? await Task.sleep(for: .seconds(1.5))
            link.resync()
            status = .done("\(summary) saved.")
        }
    }

    /// A fresh session passkey: the cached one, or ask for the owner (the
    /// answer carries one) and wait up to 6 s.
    private func passkey(link: MeshLink, me: NodeNum) async -> Data? {
        if let k = link.session.validPasskey() { return k }
        link.send(toRadio: Admin.getOwner(node: me, id: MeshCodec.newPacketID()))
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(200))
            if let k = link.session.validPasskey() { return k }
        }
        return nil
    }

    /// Makes one of the node's channels its only channel (a fox): it moves
    /// to slot 0 as primary, every other channel is removed, and the frequency
    /// slot is pinned to the one the node uses now, so it stays on the same
    /// frequency as everyone else.
    static func makeOnlyChannel(_ settings: Data, current: [Int: ChannelInfo], lora: LoRaSettings?) -> [Change] {
        var out: [Change] = [.channel(index: 0, settings: settings, role: .primary)]
        for i in 1...7 where current[i] != nil {
            out.append(.channel(index: i, settings: nil, role: .disabled))
        }
        if let lora, let slot = FrequencySlot.effective(lora: lora, primaryName: current[0]?.name ?? "") {
            out.append(.config(.lora, FrequencySlot.pinned(lora, slot: slot)))
        }
        return out
    }

    /// Channels from a Meshtastic link: `add` fills free slots; otherwise the
    /// link replaces all channels (first one primary).
    static func changes(for link: ChannelLink, current: [Int: ChannelInfo], applyRadio: Bool,
                        lora: LoRaSettings?) -> [Change] {
        var out: [Change] = []
        if link.add {
            var free = (1...7).filter { current[$0] == nil }
            for c in link.channels {
                guard !free.isEmpty else { break }
                out.append(.channel(index: free.removeFirst(), settings: c.raw, role: .secondary))
            }
        } else {
            for i in 0...7 {
                if i < link.channels.count {
                    out.append(.channel(index: i, settings: link.channels[i].raw, role: i == 0 ? .primary : .secondary))
                } else if current[i] != nil {
                    out.append(.channel(index: i, settings: nil, role: .disabled))
                }
            }
        }
        // A replacing link changes the primary channel, which moves the node to
        // another frequency slot unless the link pins one: always take the pin.
        let theirPin = link.lora.flatMap { Int((try? Proto.Message($0))?.uint32(11) ?? 0) } ?? 0
        if applyRadio || (!link.add && theirPin > 0), let raw = link.lora, var mine = lora {
            let theirs = LoRaSettings(raw: raw)
            if applyRadio {
                mine.usePreset = theirs.usePreset
                mine.preset = theirs.preset
                if theirs.region != .unset { mine.region = theirs.region }
            }
            let patched = theirPin > 0 ? Proto.patch(mine.patched, [11: Proto.varint(theirPin)]) : mine.patched
            out.append(.config(.lora, patched))
        }
        return out
    }
}
