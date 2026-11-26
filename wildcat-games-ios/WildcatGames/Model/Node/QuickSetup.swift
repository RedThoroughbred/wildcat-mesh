import Foundation
import WildcatRadioCore

/// One-tap node roles: make a spare node the fox, or a base station (Den Lite).
enum QuickSetup {
    /// The hunt channel, remembered from any node that has it, so a new fox
    /// gets the same key. `lora` is the mesh's radio settings with its
    /// frequency slot pinned.
    struct HuntChannel: Codable, Equatable {
        var settings: Data
        var lora: Data?

        var name: String { ChannelSettings(raw: settings).name }
        /// For hunters and the Den: adds the channel next to their others.
        var addLink: String { ChannelLink(channels: [ChannelSettings(raw: settings)], lora: nil, add: true).url }
    }

    static let foxPower = 10
    // Automatic sends stay at or below Meshtastic's defaults (position and device
    // telemetry hourly): LoRa airtime is shared by every node nearby. Meshtastic
    // LLC asked for this on 2026-11-25; don't lower these.
    static let foxHeartbeatSecs = 3600
    static let denTelemetrySecs = 3600
    static let denPositionSecs = 3600

    // MARK: Remembering the hunt channel

    private static let account = "hunt-channel"

    static var saved: HuntChannel? {
        get {
            guard let s = Keychain.read(account), let d = Data(base64Encoded: s) else { return nil }
            return try? JSONDecoder().decode(HuntChannel.self, from: d)
        }
        set { Keychain.write(newValue.flatMap { try? JSONEncoder().encode($0).base64EncodedString() }, for: account) }
    }

    /// The hunt channel as `session`'s node has it, if it has one.
    static func huntChannel(in s: MeshSession) -> HuntChannel? {
        guard let c = s.channels.values.first(where: { $0.name.uppercased() == HuntModel.huntChannelName }),
              let raw = c.settings else { return nil }
        var lora: Data?
        if let l = s.lora {
            let pinned = ((try? Proto.Message(l.raw))?.uint32(11) ?? 0) > 0
            // A node whose primary is WGHUNT without a pin is off the mesh's
            // frequency: don't learn the radio settings from it.
            if c.index != 0 || pinned, let slot = FrequencySlot.effective(lora: l, primaryName: s.channels[0]?.name ?? "") {
                lora = FrequencySlot.pinned(l, slot: slot)
            }
        }
        return HuntChannel(settings: raw, lora: lora)
    }

    static func remember(_ s: MeshSession) {
        guard let found = huntChannel(in: s) else { return }
        var keep = found
        if keep.lora == nil, let old = saved, old.settings == found.settings { keep.lora = old.lora }
        if keep != saved { saved = keep }
    }

    /// A brand-new hunt channel on the node's current frequency.
    static func newHuntChannel(for s: MeshSession) -> HuntChannel {
        let settings = ChannelSettings(name: HuntModel.huntChannelName, psk: ChannelSettings.randomKey()).raw
        var lora: Data?
        if let l = s.lora, let slot = FrequencySlot.effective(lora: l, primaryName: s.channels[0]?.name ?? "") {
            lora = FrequencySlot.pinned(l, slot: slot)
        }
        return HuntChannel(settings: settings, lora: lora)
    }

    // MARK: The changes

    /// The fox: the hunt channel is its only channel, on the mesh's frequency,
    /// at low power. Its position is hidden (GPS off, no fixed position) and it
    /// sends a location-free telemetry heartbeat once an hour. Hunters hear it
    /// by pinging it (a traceroute it answers), not by waiting for heartbeats.
    static func fox(_ s: MeshSession, hunt: HuntChannel) -> [NodeAdmin.Change] {
        var out: [NodeAdmin.Change] = [.channel(index: 0, settings: hunt.settings, role: .primary)]
        for i in 1...7 where s.channels[i] != nil {
            out.append(.channel(index: i, settings: nil, role: .disabled))
        }
        if var p = s.position {
            p.broadcastSecs = 43_200
            p.smart = false
            p.fixed = false
            if p.gpsMode == .enabled { p.gpsMode = .disabled }
            out.append(.config(.position, p.patched))
        }
        if s.position?.fixed == true { out.append(.clearFixedPosition) }
        var tel = s.telemetry ?? TelemetrySettings(raw: Data())
        tel.deviceUpdateSecs = foxHeartbeatSecs
        tel.deviceTelemetryEnabled = true
        out.append(.module(.telemetry, tel.patched))
        if var l = s.lora {
            let slot = hunt.lora.flatMap { Int((try? Proto.Message($0))?.uint32(11) ?? 0) }.flatMap { $0 > 0 ? $0 : nil }
                ?? FrequencySlot.effective(lora: l, primaryName: s.channels[0]?.name ?? "")
            if let raw = hunt.lora {
                let mesh = LoRaSettings(raw: raw)
                l.usePreset = mesh.usePreset
                l.preset = mesh.preset
                if mesh.region != .unset { l.region = mesh.region }
            }
            l.txPower = foxPower
            l.txEnabled = true
            out.append(.config(.lora, slot.map { FrequencySlot.pinned(l, slot: $0) } ?? l.patched))
        }
        return out
    }

    /// A base station without a computer: always relaying, fixed where it
    /// stands, a slow telemetry heartbeat, store & forward (ESP32 boards with
    /// PSRAM act on it; others ignore it), and the hunt channel if we know it.
    static func denLite(_ s: MeshSession, at spot: Coordinate?, altitude: Int?, hunt: HuntChannel?) -> [NodeAdmin.Change] {
        var out: [NodeAdmin.Change] = []
        if let hunt, !s.channels.values.contains(where: { $0.name.uppercased() == HuntModel.huntChannelName }),
           let free = (1...7).first(where: { s.channels[$0] == nil }) {
            out.append(.channel(index: free, settings: hunt.settings, role: .secondary))
        }
        if var p = s.position {
            p.broadcastSecs = denPositionSecs
            p.smart = false
            p.fixed = spot != nil || p.fixed
            out.append(.config(.position, p.patched))
        }
        if let spot { out.append(.fixedPosition(spot, altitude: altitude)) }
        var tel = s.telemetry ?? TelemetrySettings(raw: Data())
        tel.deviceUpdateSecs = denTelemetrySecs
        tel.deviceTelemetryEnabled = true
        out.append(.module(.telemetry, tel.patched))
        var sf = s.storeForward ?? StoreForwardSettings(raw: Data())
        sf.enabled = true
        sf.isServer = true
        out.append(.module(.storeForward, sf.patched))
        // Roles that don't relay (or sleep) make a poor base.
        if var d = s.device, [.clientMute, .clientHidden, .tracker, .sensor, .takTracker, .lostAndFound].contains(d.role) {
            d.role = .client
            out.append(.config(.device, d.patched))
        }
        return out
    }
}
