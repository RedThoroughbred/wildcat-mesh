import Foundation

/// What the phone knows about its connected node, built from FromRadio
/// frames: the node's own number, the node database, the channels, and
/// whether the initial config download has finished. Pure (no Bluetooth),
/// so it is tested directly and shared by every transport.
public struct MeshSession: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// The config download ended (`config_complete_id` matched).
        case ready
        case packet(MeshPacket)
        case myNode(NodeNum)
    }

    public private(set) var configID: UInt32
    public private(set) var myNode: NodeNum?
    public private(set) var nodes: [NodeNum: NodeInfo] = [:]
    public private(set) var channels: [Int: ChannelInfo] = [:]
    public private(set) var isReady = false
    /// Raw config sections as the node sent them.
    public private(set) var config: [ConfigSection: Data] = [:]
    /// Raw module config sections as the node sent them.
    public private(set) var moduleConfig: [ModuleSection: Data] = [:]
    public private(set) var firmware: String?
    /// The session passkey from the node's latest admin response, and when.
    public private(set) var passkey: Data?
    public private(set) var passkeyTime: Date?

    public var lora: LoRaSettings? { config[.lora].map(LoRaSettings.init) }
    public var device: DeviceSettings? { config[.device].map(DeviceSettings.init) }
    public var position: PositionSettings? { config[.position].map(PositionSettings.init) }
    public var telemetry: TelemetrySettings? { moduleConfig[.telemetry].map(TelemetrySettings.init) }
    public var externalNotification: ExternalNotificationSettings? {
        moduleConfig[.externalNotification].map(ExternalNotificationSettings.init)
    }
    public var storeForward: StoreForwardSettings? { moduleConfig[.storeForward].map(StoreForwardSettings.init) }
    /// A node that has never been set up: it won't transmit until a region is chosen.
    public var needsRegion: Bool { lora?.region == .unset }

    /// Our own node's User record (raw), from the node database.
    public var ownerRaw: Data? { myNode.flatMap { nodes[$0]?.userRaw } }

    /// The passkey if it's fresh enough to use (the firmware keeps it ~300 s).
    public func validPasskey(now: Date = Date()) -> Data? {
        guard let passkey, let t = passkeyTime, now.timeIntervalSince(t) < 240 else { return nil }
        return passkey
    }

    public mutating func storePasskey(_ key: Data, at t: Date = Date()) {
        passkey = key
        passkeyTime = t
    }

    /// Reflects a change we just sent, so screens show it before a resync.
    public mutating func applyLocally(_ section: ConfigSection, _ inner: Data) { config[section] = inner }
    public mutating func applyLocally(module section: ModuleSection, _ inner: Data) { moduleConfig[section] = inner }
    public mutating func applyLocally(channel: ChannelInfo) {
        if channel.role == .disabled { channels[channel.index] = nil } else { channels[channel.index] = channel }
    }

    public init(configID: UInt32 = UInt32.random(in: 1...0x0FFF_FFFF)) {
        self.configID = configID
    }

    /// The bytes that start (or restart) the config download.
    public var wantConfig: Data { MeshCodec.wantConfig(id: configID) }

    public mutating func handle(_ frame: FromRadio) -> Event? {
        switch frame {
        case .myInfo(let n):
            myNode = n
            return .myNode(n)
        case .nodeInfo(let info):
            nodes[info.num] = info
            return nil
        case .channel(let c):
            if c.role == .disabled { channels[c.index] = nil } else { channels[c.index] = c }
            return nil
        case .configComplete(let id):
            guard id == configID, !isReady else { return nil }
            isReady = true
            return .ready
        case .packet(let p):
            learn(from: p)
            if p.rawPortnum == Admin.portnum, p.from == myNode, let payload = p.payload,
               let r = Admin.response(p, payload: payload), let key = r.passkey {
                storePasskey(key)
            }
            return .packet(p)
        case .config(let section, let data):
            config[section] = data
            return nil
        case .moduleConfig(let section, let data):
            moduleConfig[section] = data
            return nil
        case .metadata(let fw):
            firmware = fw
            return nil
        case .other:
            return nil
        }
    }

    /// Keeps the node database current from traffic, as the firmware does:
    /// last heard, signal, hops, and whatever the packet carries (position,
    /// telemetry, names).
    mutating func learn(from p: MeshPacket, at now: Date = Date()) {
        guard p.from.raw != 0 else { return }
        var n = nodes[p.from] ?? NodeInfo(num: p.from)
        n.lastHeard = now
        if let s = p.rxSNR, p.rxRSSI != nil || s != 0 { n.snr = s }
        if let h = p.hops { n.hopsAway = h }
        n.viaMQTT = p.viaMQTT
        if !p.isEncrypted { n.channel = p.channel }
        if let c = p.position { n.position = c; n.positionTime = now }
        if let m = p.metrics { n.metrics = m }
        if let u = p.user {
            n.userRaw = u.raw
            n.longName = u.longName ?? n.longName
            n.shortName = u.shortName ?? n.shortName
            n.hwModel = u.hwModel ?? n.hwModel
        }
        nodes[p.from] = n
    }

    /// Reflects a favourite/ignore/remove we just sent.
    public mutating func setFlags(_ node: NodeNum, favorite: Bool? = nil, ignored: Bool? = nil, remove: Bool = false) {
        if remove { nodes[node] = nil; return }
        if let favorite { nodes[node]?.isFavorite = favorite }
        if let ignored { nodes[node]?.isIgnored = ignored }
    }

    /// The channel to reach `node` on: where we last heard it, else WGHUNT, else primary.
    public func channel(toReach node: NodeNum) -> Int {
        nodes[node]?.channel ?? channelIndex(named: "WGHUNT") ?? 0
    }

    /// Channel index by name, case-insensitive ("WGHUNT"). The primary
    /// channel may have an empty name, so it is never matched by name.
    public func channelIndex(named name: String) -> Int? {
        let n = name.lowercased()
        return channels.values.first { !$0.name.isEmpty && $0.name.lowercased() == n }?.index
    }

    /// A node's short name ("DEN") or its "!xxxxxxxx" id.
    public func label(for node: NodeNum) -> String {
        nodes[node]?.shortName.flatMap { $0.isEmpty ? nil : $0 } ?? node.id
    }
}
