#if DEBUG
import Foundation
import WildcatRadioCore

/// Developer only: `-RNodeAutoTest` drives the RNode console from the Mac so a real RNode can be
/// checked without touching the phone's screen (`xcrun devicectl device process launch --console`
/// shows the log). Scans, connects to the strongest RNode (or the last one), prints what
/// `rnodeconf --info` would, reads the radio settings, changes the spreading factor and reads it
/// back, puts it back, then watches signal and battery for a while. It never transmits.
/// With `-RNodeAutoTestListen` it then sets the radio to the test settings Seth's Macs use
/// (914.875 MHz, 125 kHz, SF8, CR 4/5, 7 dBm) and turns the receiver on, and logs every packet
/// heard with its decoded Reticulum header ("Heard on air"). Turning the radio on doesn't make an
/// RNode transmit: it only sends what its host gives it, and this never gives it anything.
@MainActor
final class RNodeAutoTest {
    static let shared = RNodeAutoTest()
    private var link: RNodeLink?
    private var step = 0
    private var originalSF: Int?
    private var started = false

    func start(_ link: RNodeLink) {
        guard !started else { return }
        started = true
        self.link = link
        log("start; last node \(link.lastNodeName ?? "none")")
        link.onDiagnostic = { [weak self] in self?.log("diag: \($0)") }
        link.addListener { [weak self] in self?.handle($0) }
        if link.lastNodeID != nil {
            log("reconnecting the last RNode")
            link.reconnectLast()
        } else {
            link.scan()
        }
        Task { @MainActor [weak self] in
            // Scanning: connect to the strongest RNode after a few seconds.
            try? await Task.sleep(for: .seconds(6))
            guard let self, let link = self.link, link.state == .scanning else { return }
            let rnodes = link.discovered.filter(\.isRNode).sorted { $0.rssi > $1.rssi }
            self.log("found \(link.discovered.count) UART devices, \(rnodes.count) RNodes: \(rnodes.map { "\($0.name) \($0.rssi) dBm" })")
            if let best = rnodes.first { link.connect(best.id) } else { self.log("no RNode found; still scanning") }
        }
        Task { @MainActor [weak self] in
            var last: RNodeLink.State?
            for _ in 0..<600 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let link = self.link else { return }
                if link.state != last {
                    last = link.state
                    self.log("state: \(link.state)")
                }
            }
        }
    }

    private func handle(_ e: RNodeSession.Event) {
        guard let link else { return }
        switch e {
        case .ready:
            for l in link.session.device.infoLines() { log("info | \(l)") }
            logParameters("params")
            step = 1
            originalSF = link.session.parameters.spreadingFactor
            let current = originalSF ?? 7
            let next = current == 12 ? 7 : current + 1
            let was = originalSF.map { String($0) } ?? "unset"
            log("setting SF \(next) (was \(was))")
            link.setSpreadingFactor(next)
        case .parametersChanged where step == 1:
            if let o = originalSF, link.session.parameters.spreadingFactor != o {
                logParameters("after set")
                step = 2
                log("restoring SF \(o)")
                link.setSpreadingFactor(o)
            }
        case .parametersChanged where step == 2:
            if link.session.parameters.spreadingFactor == originalSF {
                logParameters("restored")
                step = 3
                log("reading counters")
                link.refreshCounters()
                if ProcessInfo.processInfo.arguments.contains("-RNodeAutoTestListen") { listen() }
            }
        case .parametersChanged where step == 4:
            if link.session.parameters.radioOn == true {
                step = 5
                logParameters("listening")
                log("radio on, receive only: packets follow as `heard |` lines")
            }
        case .channelStats:
            if let c = link.session.channel {
                log("channel | rssi \(c.rssi) dBm · noise \(c.noiseFloor) dBm · airtime \(c.airtimeShort)% / \(c.airtimeLong)% · load \(c.channelLoadShort)% / \(c.channelLoadLong)%")
            }
        case .battery:
            if let b = link.session.battery { log("battery | \(b.percent)% \(b.stateWord)") }
        case .packet(let d):
            let rssi = link.session.signal?.rssi.map { String($0) } ?? "?"
            let snr = link.session.signal?.snr.map { String($0) } ?? "?"
            log("packet | \(d.count) bytes, rssi \(rssi) snr \(snr)")
            if let h = link.session.heard.first { log("heard | " + Self.describe(h)) }
        case .error(let c):
            log("error | \(c.text)")
        case .detected(let ok):
            log("detected: \(ok)")
        default:
            break
        }
    }

    /// The test settings on both Macs' RNodes (`~/.reticulum/config`, `rnode2/config`).
    nonisolated static let listenSettings = (frequencyHz: UInt32(914_875_000), bandwidthHz: UInt32(125_000), sf: 8, cr: 5, txPower: 7)

    private func listen() {
        guard let link else { return }
        let s = Self.listenSettings
        step = 4
        log("listen: setting \(RNode.mHzText(s.frequencyHz)) MHz · \(RNode.kHzText(s.bandwidthHz)) kHz · SF \(s.sf) · CR \(s.cr) · \(s.txPower) dBm, then radio on")
        link.setFrequency(hz: s.frequencyHz)
        link.setBandwidth(hz: s.bandwidthHz)
        link.setTxPower(s.txPower)
        link.setSpreadingFactor(s.sf)
        link.setCodingRate(s.cr)
        link.setRadio(on: true)
    }

    /// "Announce <53802fdd…> single · direct · 188 B · −101 dBm · SNR 6.5 · dest 53802fdd…1de1d"
    nonisolated static func describe(_ h: RNodeSession.HeardPacket) -> String {
        var line = "\(h.kind.word) "
        if let p = h.packet { line += RNodeHeardFormat.destination(p) + " " }
        line += RNodeHeardFormat.subtitle(h)
        if let p = h.packet { line += " · dest \(ReticulumPacket.hex(p.destinationHash))" }
        if case .unreadable(let why) = h.reading { line += " · \(why.text)" }
        return line
    }

    private func logParameters(_ tag: String) {
        guard let p = link?.session.parameters else { return }
        let freq = p.frequencyHz.map { RNode.mHzText($0) } ?? "unset"
        let bw = p.bandwidthHz.map { RNode.kHzText($0) } ?? "unset"
        let txp = p.txPower.map { String($0) } ?? "unset"
        let sf = p.spreadingFactor.map { String($0) } ?? "unset"
        let cr = p.codingRate.map { String($0) } ?? "unset"
        let radio = p.radioOn.map { $0 ? "on" : "off" } ?? "?"
        log("\(tag) | freq \(freq) MHz · bw \(bw) kHz · txp \(txp) dBm · SF \(sf) · CR \(cr) · radio \(radio)")
    }

    private func log(_ s: String) {
        let line = "[RNodeAutoTest] \(s)"
        print(line)
        NSLog("%@", line)
    }
}
#endif
