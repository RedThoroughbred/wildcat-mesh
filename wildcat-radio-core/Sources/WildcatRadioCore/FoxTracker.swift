import Foundation

/// The hunter's live meter: watches every packet the hunter's own node
/// receives, keeps the ones heard directly from the fox, and decides when
/// to report a reading to the Den (`WG SIG`). Pure and clock-free: callers
/// pass each packet with its arrival time.
public struct FoxTracker: Equatable, Sendable {
    public struct Sample: Equatable, Sendable {
        public var time: Date
        public var rssi: Int?
        public var snr: Double?
        /// 0–100, the Den's `signal_score` (RSSI when known, else SNR).
        public var score: Double
    }

    public enum Trend: Equatable, Sendable { case none, warmer, colder, steady }

    public var fox: NodeNum
    /// Direct-RF samples, oldest first (the last `keep`).
    public private(set) var samples: [Sample] = []
    public private(set) var best: Sample?
    public private(set) var lastReported: Sample?
    /// Packets from the fox that arrived relayed or via MQTT (they say the
    /// fox is alive, not how far away it is).
    public private(set) var indirectCount = 0

    /// Samples kept for the chart.
    public var keep = 240
    /// Report at most this often, unless the reading jumps.
    public var reportInterval: TimeInterval = 30
    /// A change this large (dB of RSSI) is reported right away (≥ 5 s apart).
    public var reportJump = 3.0
    /// Also count packets the fox *relayed* to us: their rx signal is the
    /// fox's transmission (relay_node is the low byte of the last relayer).
    /// For hunting real repeaters, which mostly relay others' traffic.
    public var acceptRelayed = false
    /// Samples that came from relayed packets.
    public private(set) var relayedCount = 0

    public init(fox: NodeNum) { self.fox = fox }

    public static func score(rssi: Int?, snr: Double?) -> Double? {
        if let rssi { return max(0, min(100, (Double(rssi) + 125) / 80 * 100)) }
        if let snr { return max(0, min(100, (snr + 20) / 32 * 100)) }
        return nil
    }

    /// Feeds one received packet. Returns the sample when it was a direct
    /// reading of the fox.
    @discardableResult
    public mutating func ingest(_ packet: MeshPacket, at time: Date) -> Sample? {
        let relayedByFox = acceptRelayed && !packet.viaMQTT && packet.from != fox
            && (packet.hops ?? 0) > 0 && packet.relayNode == fox.relayByte && fox.relayByte != 0
        if relayedByFox {
            relayedCount += 1
        } else {
            guard packet.from == fox else { return nil }
            guard packet.isDirectRF else {
                indirectCount += 1
                return nil
            }
        }
        let snr = packet.rxSNR.map(Double.init)
        guard let score = Self.score(rssi: packet.rxRSSI, snr: snr) else { return nil }
        let s = Sample(time: time, rssi: packet.rxRSSI, snr: snr, score: score)
        samples.append(s)
        if samples.count > keep { samples.removeFirst(samples.count - keep) }
        if best == nil || score > best!.score { best = s }
        return s
    }

    public var latest: Sample? { samples.last }

    /// Local warmer/colder from the last two samples, with the Den's steps
    /// (3 dB RSSI, 1.5 dB SNR).
    public var trend: Trend {
        guard samples.count >= 2 else { return .none }
        let a = samples[samples.count - 2], b = samples[samples.count - 1]
        let d: Double, step: Double
        if let ra = a.rssi, let rb = b.rssi { d = Double(rb - ra); step = 3 }
        else if let sa = a.snr, let sb = b.snr { d = sb - sa; step = 1.5 }
        else { d = b.score - a.score; step = 4 }
        return d >= step ? .warmer : d <= -step ? .colder : .steady
    }

    /// The `WG SIG` to send now, if one is due: the first reading, a jump of
    /// `reportJump`, or `reportInterval` since the last report.
    public mutating func reportIfDue(hunt: String?, at now: Date) -> WG.Command? {
        guard let s = latest else { return nil }
        let due: Bool
        if let last = lastReported {
            let since = now.timeIntervalSince(last.time)
            let jump: Double
            if let r0 = last.rssi, let r1 = s.rssi { jump = abs(Double(r1 - r0)) }
            else if let s0 = last.snr, let s1 = s.snr { jump = abs(s1 - s0) * 2 }
            else { jump = 0 }
            due = s.time > last.time && (since >= reportInterval || (jump >= reportJump && since >= 5))
        } else {
            due = true
        }
        guard due else { return nil }
        lastReported = s
        return .sig(hunt: hunt, WG.Signal(rssi: s.rssi, snr: s.snr.map { ($0 * 10).rounded() / 10 }))
    }
}
