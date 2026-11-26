import Foundation
import WildcatRadioCore

/// A radio the user owns, on either network, as it was last seen: what it is,
/// how it's set up, and how it was doing. Saved on the phone. Holds no
/// passwords and no channel keys (channel names only).
struct OwnedNode: Codable, Equatable, Identifiable {
    enum Network: String, Codable { case meshtastic, meshcore }

    /// How it got into My Mesh.
    enum Origin: String, Codable { case connected, admin, manual, practice }

    struct RadioSettings: Codable, Equatable {
        // Meshtastic
        var region: String?
        var preset: String?
        var slot: Int?
        var channels: [String]?
        // MeshCore
        var frequencyMHz: Double?
        var bandwidthKHz: Double?
        var spreadingFactor: Int?
        var codingRate: Int?
        /// Both networks; nil when unknown or the board's default.
        var txPowerDBm: Int?
        /// Copied from the companion that logged in (a repeater has to match it to be heard).
        var inferred: Bool?

        /// "910.525 MHz · 62.5 kHz · SF7 · CR5 · 22 dBm" or "US 915 · Long Fast · slot 20".
        var summary: String {
            var parts: [String] = []
            if let region { parts.append(region) }
            if let preset { parts.append(preset) }
            if let slot { parts.append("slot \(slot)") }
            if let f = frequencyMHz { parts.append(String(format: "%.3f MHz", f)) }
            if let b = bandwidthKHz { parts.append(OwnedNode.trim(b) + " kHz") }
            if let s = spreadingFactor { parts.append("SF\(s)") }
            if let c = codingRate { parts.append("CR\(c)") }
            if let t = txPowerDBm { parts.append("\(t) dBm") }
            return parts.joined(separator: " · ")
        }

        init(region: String? = nil, preset: String? = nil, slot: Int? = nil, channels: [String]? = nil,
             frequencyMHz: Double? = nil, bandwidthKHz: Double? = nil, spreadingFactor: Int? = nil,
             codingRate: Int? = nil, txPowerDBm: Int? = nil, inferred: Bool? = nil) {
            self.region = region; self.preset = preset; self.slot = slot; self.channels = channels
            self.frequencyMHz = frequencyMHz; self.bandwidthKHz = bandwidthKHz; self.spreadingFactor = spreadingFactor
            self.codingRate = codingRate; self.txPowerDBm = txPowerDBm; self.inferred = inferred
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            region = try? c.decodeIfPresent(String.self, forKey: .region)
            preset = try? c.decodeIfPresent(String.self, forKey: .preset)
            slot = try? c.decodeIfPresent(Int.self, forKey: .slot)
            channels = try? c.decodeIfPresent([String].self, forKey: .channels)
            frequencyMHz = try? c.decodeIfPresent(Double.self, forKey: .frequencyMHz)
            bandwidthKHz = try? c.decodeIfPresent(Double.self, forKey: .bandwidthKHz)
            spreadingFactor = try? c.decodeIfPresent(Int.self, forKey: .spreadingFactor)
            codingRate = try? c.decodeIfPresent(Int.self, forKey: .codingRate)
            txPowerDBm = try? c.decodeIfPresent(Int.self, forKey: .txPowerDBm)
            inferred = try? c.decodeIfPresent(Bool.self, forKey: .inferred)
        }
    }

    /// A repeater's latest status reply (from repeater admin).
    struct RepeaterSnapshot: Codable, Equatable {
        var uptimeSeconds: Int?
        var packetsRelayed: Int?
        var packetsHeard: Int?
        var noiseFloor: Int?
        var batteryMillivolts: Int?
        var at: Date?

        init(uptimeSeconds: Int? = nil, packetsRelayed: Int? = nil, packetsHeard: Int? = nil, noiseFloor: Int? = nil,
             batteryMillivolts: Int? = nil, at: Date? = nil) {
            self.uptimeSeconds = uptimeSeconds; self.packetsRelayed = packetsRelayed; self.packetsHeard = packetsHeard
            self.noiseFloor = noiseFloor; self.batteryMillivolts = batteryMillivolts; self.at = at
        }

        init(_ s: MeshCore.RepeaterStatus, at: Date) {
            self.init(uptimeSeconds: Int(s.uptimeSeconds), packetsRelayed: Int(s.packetsSent), packetsHeard: Int(s.packetsReceived),
                      noiseFloor: s.noiseFloor, batteryMillivolts: s.batteryMillivolts, at: at)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uptimeSeconds = try? c.decodeIfPresent(Int.self, forKey: .uptimeSeconds)
            packetsRelayed = try? c.decodeIfPresent(Int.self, forKey: .packetsRelayed)
            packetsHeard = try? c.decodeIfPresent(Int.self, forKey: .packetsHeard)
            noiseFloor = try? c.decodeIfPresent(Int.self, forKey: .noiseFloor)
            batteryMillivolts = try? c.decodeIfPresent(Int.self, forKey: .batteryMillivolts)
            at = try? c.decodeIfPresent(Date.self, forKey: .at)
        }
    }

    var network: Network
    /// Meshtastic "!9e766b18"; MeshCore the 6-byte public key prefix in hex.
    var nodeID: String
    var name: String
    var shortName: String?
    var hardware: String?
    var firmware: String?
    /// Meshtastic `DeviceRole` raw value; MeshCore advert type (1 companion, 2 repeater, 3 room server, 4 sensor).
    var roleCode: Int?
    var radio: RadioSettings?
    var batteryVolts: Double?
    /// 0-100, or 101 for "powered" (Meshtastic's convention).
    var batteryPercent: Int?
    var sharesLocation: Bool?
    var lastConnected: Date?
    var lastHeard: Date?
    var repeater: RepeaterSnapshot?
    /// The phone's Bluetooth id for it, so Connect can go straight to it.
    var bluetoothID: UUID?
    var origin: Origin
    var added: Date

    var id: String { Self.id(network, nodeID) }
    static func id(_ network: Network, _ nodeID: String) -> String { network.rawValue + ":" + nodeID.lowercased() }

    init(network: Network, nodeID: String, name: String, shortName: String? = nil, hardware: String? = nil,
         firmware: String? = nil, roleCode: Int? = nil, radio: RadioSettings? = nil, batteryVolts: Double? = nil,
         batteryPercent: Int? = nil, sharesLocation: Bool? = nil, lastConnected: Date? = nil, lastHeard: Date? = nil,
         repeater: RepeaterSnapshot? = nil, bluetoothID: UUID? = nil, origin: Origin, added: Date = Date()) {
        self.network = network; self.nodeID = nodeID.lowercased(); self.name = name; self.shortName = shortName
        self.hardware = hardware; self.firmware = firmware; self.roleCode = roleCode; self.radio = radio
        self.batteryVolts = batteryVolts; self.batteryPercent = batteryPercent; self.sharesLocation = sharesLocation
        self.lastConnected = lastConnected; self.lastHeard = lastHeard; self.repeater = repeater
        self.bluetoothID = bluetoothID; self.origin = origin; self.added = added
    }

    /// Only the network and id are required; anything else missing or unreadable is left empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        network = try c.decode(Network.self, forKey: .network)
        nodeID = try c.decode(String.self, forKey: .nodeID).lowercased()
        name = (try? c.decodeIfPresent(String.self, forKey: .name))?.nonBlank ?? nodeID
        shortName = try? c.decodeIfPresent(String.self, forKey: .shortName)
        hardware = try? c.decodeIfPresent(String.self, forKey: .hardware)
        firmware = try? c.decodeIfPresent(String.self, forKey: .firmware)
        roleCode = try? c.decodeIfPresent(Int.self, forKey: .roleCode)
        radio = try? c.decodeIfPresent(RadioSettings.self, forKey: .radio)
        batteryVolts = try? c.decodeIfPresent(Double.self, forKey: .batteryVolts)
        batteryPercent = try? c.decodeIfPresent(Int.self, forKey: .batteryPercent)
        sharesLocation = try? c.decodeIfPresent(Bool.self, forKey: .sharesLocation)
        lastConnected = try? c.decodeIfPresent(Date.self, forKey: .lastConnected)
        lastHeard = try? c.decodeIfPresent(Date.self, forKey: .lastHeard)
        repeater = try? c.decodeIfPresent(RepeaterSnapshot.self, forKey: .repeater)
        bluetoothID = try? c.decodeIfPresent(UUID.self, forKey: .bluetoothID)
        origin = (try? c.decodeIfPresent(Origin.self, forKey: .origin)) ?? .manual
        added = (try? c.decodeIfPresent(Date.self, forKey: .added)) ?? Date()
    }

    // MARK: Merging

    /// Takes everything `fresh` knows and keeps what it doesn't. Times only move forward.
    mutating func merge(_ fresh: OwnedNode) {
        guard fresh.id == id else { return }
        if !fresh.name.isEmpty, fresh.name != fresh.nodeID || name.isEmpty { name = fresh.name }
        shortName = fresh.shortName ?? shortName
        hardware = fresh.hardware ?? hardware
        firmware = fresh.firmware ?? firmware
        roleCode = fresh.roleCode ?? roleCode
        if let r = fresh.radio {
            // Settings copied from a companion never replace ones read from the node itself.
            if r.inferred != true || radio == nil || radio?.inferred == true { radio = r }
        }
        batteryVolts = fresh.batteryVolts ?? batteryVolts
        batteryPercent = fresh.batteryPercent ?? batteryPercent
        sharesLocation = fresh.sharesLocation ?? sharesLocation
        lastConnected = Self.later(lastConnected, fresh.lastConnected)
        lastHeard = Self.later(lastHeard, fresh.lastHeard)
        if let s = fresh.repeater, (s.at ?? .distantPast) >= (repeater?.at ?? .distantPast) { repeater = s }
        bluetoothID = fresh.bluetoothID ?? bluetoothID
        added = min(added, fresh.added)
    }

    static func later(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        default: return a ?? b
        }
    }

    // MARK: Building from what the radios report

    /// The connected Meshtastic node, from its session (config, node database, channels).
    static func meshtastic(_ s: MeshSession, bluetoothID: UUID? = nil, now: Date = Date()) -> OwnedNode? {
        guard let me = s.myNode else { return nil }
        let info = s.nodes[me]
        var n = OwnedNode(network: .meshtastic, nodeID: me.id, name: info?.longName.flatMap(\.nonBlank) ?? me.id,
                          shortName: info?.shortName.flatMap(\.nonBlank), hardware: info?.hardware, firmware: s.firmware,
                          roleCode: s.device?.role.rawValue ?? info?.role, lastConnected: now, lastHeard: now,
                          bluetoothID: bluetoothID, origin: .connected, added: now)
        if let lora = s.lora {
            let primary = s.channels[0]?.name ?? ""
            let names = s.channels.values.sorted { $0.index < $1.index }.map {
                $0.name.isEmpty ? FrequencySlot.presetName(lora.preset, usePreset: lora.usePreset) : $0.name
            }
            n.radio = RadioSettings(region: lora.region == .unset ? "No region" : regionShort(lora.region),
                                    preset: lora.usePreset ? presetShort(lora.preset) : "Custom",
                                    slot: FrequencySlot.effective(lora: lora, primaryName: primary),
                                    channels: names, txPowerDBm: lora.txPower > 0 ? lora.txPower : nil)
        }
        if let m = info?.metrics { n.batteryPercent = m.batteryLevel; n.batteryVolts = m.voltage }
        if let p = s.position { n.sharesLocation = p.fixed || p.gpsMode == .enabled }
        else if info?.position != nil { n.sharesLocation = true }
        return n
    }

    /// Another Meshtastic node the user says is theirs (or one we hear that already is).
    static func meshtastic(_ info: NodeInfo, origin: Origin = .manual, now: Date = Date()) -> OwnedNode {
        var n = OwnedNode(network: .meshtastic, nodeID: info.num.id, name: info.longName.flatMap(\.nonBlank) ?? info.num.id,
                          shortName: info.shortName.flatMap(\.nonBlank), hardware: info.hardware, roleCode: info.role,
                          lastHeard: info.lastHeard, origin: origin, added: now)
        if let m = info.metrics { n.batteryPercent = m.batteryLevel; n.batteryVolts = m.voltage }
        if info.position != nil { n.sharesLocation = true }
        return n
    }

    /// The connected MeshCore companion, from its self info and device info.
    static func meshcore(_ s: MeshCoreSession, bluetoothID: UUID? = nil, now: Date = Date()) -> OwnedNode? {
        guard let me = s.me else { return nil }
        let hw = s.device.map(\.manufacturer).flatMap(\.nonBlank)
        return OwnedNode(network: .meshcore, nodeID: OwnedNode.hex(me.publicKey.prefix(6)),
                         name: me.name.nonBlank ?? OwnedNode.hex(me.publicKey.prefix(4)), hardware: hw,
                         firmware: s.device.map(\.version).flatMap(\.nonBlank), roleCode: Int(me.advertType),
                         radio: radio(me), batteryVolts: s.batteryMillivolts.map { Double($0) / 1000 },
                         sharesLocation: me.advertLocationPolicy != 0, lastConnected: now, lastHeard: now,
                         bluetoothID: bluetoothID, origin: .connected, added: now)
    }

    static func radio(_ me: MeshCore.SelfInfo) -> RadioSettings {
        RadioSettings(frequencyMHz: me.frequency, bandwidthKHz: me.bandwidth, spreadingFactor: me.spreadingFactor,
                      codingRate: me.codingRate, txPowerDBm: me.txPower)
    }

    /// A MeshCore contact: a repeater you logged in to as admin, or one you marked as yours.
    static func meshcore(_ c: MeshCore.Contact, companion: MeshCore.SelfInfo? = nil, origin: Origin, now: Date = Date()) -> OwnedNode {
        var r = companion.map(radio)
        r?.txPowerDBm = nil
        r?.inferred = true
        return OwnedNode(network: .meshcore, nodeID: OwnedNode.hex(c.prefix), name: c.name.nonBlank ?? c.shortID,
                         roleCode: Int(c.kind.rawValue), radio: r, sharesLocation: c.position != nil,
                         lastHeard: c.lastAdvert, origin: origin, added: now)
    }

    /// "US 915" from "United States (915 MHz)".
    static func regionShort(_ r: Region) -> String {
        switch r {
        case .us: return "US 915"
        case .eu868: return "EU 868"
        case .eu433: return "EU 433"
        case .anz: return "ANZ 915"
        default: return r.title
        }
    }

    static func presetShort(_ p: ModemPreset) -> String {
        p.title.replacingOccurrences(of: " (default)", with: "")
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
}

private extension String {
    /// nil for an empty or all-space string.
    var nonBlank: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
