import SwiftUI
import WildcatRadioCore

/// The RNode's five radio settings and the radio switch, each with a plain-English line.
/// Every save goes to the RNode over KISS at once; what's shown is what the RNode reports back.
/// Settings last until the RNode reboots (Reticulum starts with them, or with the last start's).
struct RNodeSettingsView: View {
    @Environment(RNodeLink.self) private var link
    @State private var freq = ""
    @State private var bandwidth: UInt32 = 125_000
    @State private var sf = 8
    @State private var cr = 5
    @State private var power = 7
    @State private var loaded = false
    @State private var sentAt: Date?
    @State private var sentWhat = ""

    var body: some View {
        let p = link.session.parameters
        let model = link.session.device.model
        Form {
            Section { header(p) }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            statusSection
            frequencySection(p, model)
            bandwidthSection(p)
            spreadingSection(p)
            codingSection(p)
            powerSection(p, model)
            radioSection(p)
            readSection
        }
        .fieldForm()
        .tint(RNodeStyle.color)
        .navigationTitle("RNode radio")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { load() }
        .onChange(of: link.session.parameters) { old, new in adopt(old, new) }
    }

    // MARK: Sections

    private func header(_ p: RNode.RadioParameters) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconTile(symbol: RNodeStyle.symbol, tint: RNodeStyle.color, size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(name).font(.system(.title3, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Tag("RNode", color: RNodeStyle.color)
                    }
                    Text([link.session.productText, link.session.device.firmwareVersion.map { "fw \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Fonts.raw).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if p.canTurnOn {
                RadioChips(frequency: p.frequencyMHz, bandwidth: p.bandwidthKHz, spreadingFactor: p.spreadingFactor,
                           codingRate: p.codingRate, txPower: p.txPower)
            } else {
                Text(RNodeFormat.unsetList(p)).font(Theme.Fonts.detail).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .instrumentPanel()
    }

    @ViewBuilder private var statusSection: some View {
        if let sentAt {
            TimelineView(.periodic(from: .now, by: 1)) { t in
                if t.date.timeIntervalSince(sentAt) < 4 {
                    Section { Notice(text: "\(sentWhat) sent. The value shown is what the RNode reports back.", color: Theme.ok, symbol: "checkmark.circle") }
                        .fieldSection()
                }
            }
        }
    }

    private func frequencySection(_ p: RNode.RadioParameters, _ model: RNode.Model?) -> some View {
        let hz = Double(freq).map { UInt32(clamping: Int(($0 * 1_000_000).rounded())) }
        let problems = RNode.RadioParameters.problems(frequencyHz: hz, model: model)
        return Section {
            LabeledContent("Frequency (MHz)") {
                TextField("914.875", text: $freq).keyboardType(.decimalPad).multilineTextAlignment(.trailing).font(Theme.Fonts.data)
            }
            ForEach(problems.map(\.text), id: \.self) { Text($0).font(Theme.Fonts.footnote).foregroundStyle(Theme.alert) }
            saveButton("Set frequency", disabled: hz == nil || !problems.isEmpty || hz == p.frequencyHz) {
                if let hz { link.setFrequency(hz: hz) }
            }
        } header: { ModuleHeader(1, "Frequency", detail: p.frequencyHz.map { "\(RNode.mHzText($0)) MHz on the RNode" } ?? "unset") } footer: {
            Text("The channel, in MHz. " + (model.map { "This board is built for \(RNode.mHzText($0.minHz))–\(RNode.mHzText($0.maxHz)) MHz. " } ?? "")
                 + "Use a frequency you're allowed to use where you are (in the US, 902–928 MHz is licence-free). All four radio settings must match the other RNode exactly.")
        }
        .fieldSection()
    }

    private func bandwidthSection(_ p: RNode.RadioParameters) -> some View {
        Section {
            Picker("Bandwidth (kHz)", selection: $bandwidth) {
                ForEach(RNode.RadioParameters.bandwidths, id: \.self) { Text(RNode.kHzText($0)).tag($0) }
            }
            saveButton("Set bandwidth", disabled: bandwidth == p.bandwidthHz) { link.setBandwidth(hz: bandwidth) }
        } header: { ModuleHeader(2, "Bandwidth", detail: p.bandwidthHz.map { "\(RNode.kHzText($0)) kHz on the RNode" } ?? "unset") } footer: {
            Text("How wide the signal is. Wider is faster but hears less far and picks up more noise. 125 kHz is the common choice; 62.5 kHz or less for long, slow links. It must match the other RNode exactly.")
        }
        .fieldSection()
    }

    private func spreadingSection(_ p: RNode.RadioParameters) -> some View {
        let kbps = RNode.bitrateKbps(spreadingFactor: sf, bandwidthHz: bandwidth, codingRate: cr)
        return Section {
            Stepper("Spreading factor: \(sf)", value: $sf, in: RNode.RadioParameters.spreadingFactors)
            if let kbps {
                Text("About \(RNodeFormat.kbps(kbps)) kbps on air with these settings.")
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
            }
            saveButton("Set spreading factor", disabled: sf == p.spreadingFactor) { link.setSpreadingFactor(sf) }
        } header: { ModuleHeader(3, "Spreading factor", detail: p.spreadingFactor.map { "SF\($0) on the RNode" } ?? "unset") } footer: {
            Text("How long each symbol is stretched, 5 to 12. Each step up roughly halves the speed and buys about 2.5 dB of range. SF7–SF8 for nearby and fast; SF10–SF12 for far and slow. It must match the other RNode exactly.")
        }
        .fieldSection()
    }

    private func codingSection(_ p: RNode.RadioParameters) -> some View {
        Section {
            Stepper("Coding rate: 4/\(cr)", value: $cr, in: RNode.RadioParameters.codingRates)
            saveButton("Set coding rate", disabled: cr == p.codingRate) { link.setCodingRate(cr) }
        } header: { ModuleHeader(4, "Coding rate", detail: p.codingRate.map { "4/\($0) on the RNode" } ?? "unset") } footer: {
            Text("Error correction added to each packet: 4/5 adds a little, 4/8 adds a lot and halves the speed. 4/5 is usual; go higher on noisy channels. It must match the other RNode exactly.")
        }
        .fieldSection()
    }

    private func powerSection(_ p: RNode.RadioParameters, _ model: RNode.Model?) -> some View {
        let maxPower = model?.maxTxPower ?? RNode.RadioParameters.txPowerLimits.upperBound
        let mW = pow(10, Double(power) / 10)
        return Section {
            Stepper("Transmit power: \(power) dBm", value: $power, in: 0...maxPower)
            Text(String(format: "%.0f dBm is about %.0f mW.", Double(power), mW))
                .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
            saveButton("Set transmit power", disabled: power == p.txPower) { link.setTxPower(power) }
        } header: { ModuleHeader(5, "Transmit power", detail: p.txPower.map { "\($0) dBm on the RNode" } ?? "unset") } footer: {
            Text("How loud it transmits when Reticulum sends, up to \(maxPower) dBm on this board. The console itself never transmits. Use the least that works: it saves battery and leaves the channel to others.")
        }
        .fieldSection()
    }

    private func radioSection(_ p: RNode.RadioParameters) -> some View {
        Section {
            Toggle(isOn: Binding(get: { p.radioOn == true }, set: { link.setRadio(on: $0); mark("Radio \($0 ? "on" : "off")") })) {
                Text(p.radioOn == true ? "Radio on" : "Radio off")
            }
            .disabled(!p.canTurnOn)
            if !p.canTurnOn {
                Text(RNodeFormat.radioLockText(p))
                    .font(Theme.Fonts.footnote).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                // The steppers above show a starting value, which is not yet a value on the RNode.
                saveButton("Set all five now", disabled: allFive == nil) {
                    if let a = allFive {
                        link.setAll(frequencyHz: a, bandwidthHz: bandwidth, txPower: power, spreadingFactor: sf, codingRate: cr)
                    }
                }
                if allFive == nil {
                    Text("Type a frequency this board can use first.")
                        .font(Theme.Fonts.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
        } header: { ModuleHeader(6, "Radio") } footer: {
            Text("On: the modem listens with these settings and reports the noise floor, channel load and any packet it hears. Off: it sleeps. Reticulum turns it on itself when it connects.")
        }
        .fieldSection()
    }

    private var readSection: some View {
        Section {
            Button {
                link.refreshParameters()
                mark("Read request")
            } label: { Label("Read all settings again", systemImage: "arrow.clockwise") }
        } header: { ModuleHeader(7, "From the RNode") } footer: {
            Text("Every setting here is written to the RNode straight away and read back from its answer. They last until the RNode reboots; rnodeconf can save a set to its EEPROM for standalone (TNC) use.")
        }
        .fieldSection()
    }

    // MARK: Helpers

    private var name: String {
        if case .ready(let n) = link.state { return n }
        return "RNode"
    }

    private func saveButton(_ title: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(title) {
            action()
            mark(title.replacingOccurrences(of: "Set ", with: "").capitalizedFirstLetter)
            Haptics.success()
        }
        .buttonStyle(.field(.primary, .regular))
        .disabled(disabled || !link.state.isReady)
    }

    private func mark(_ what: String) {
        sentWhat = what
        sentAt = Date()
    }

    /// The frequency typed above, when it is one this board takes: what "Set all five" sends.
    private var allFive: UInt32? {
        guard let mhz = Double(freq) else { return nil }
        let hz = UInt32(clamping: Int((mhz * 1_000_000).rounded()))
        return RNode.RadioParameters.problems(frequencyHz: hz, model: link.session.device.model).isEmpty ? hz : nil
    }

    /// The RNode reported a change: show it in that field only, so one answer doesn't undo
    /// what is being typed in the others.
    private func adopt(_ old: RNode.RadioParameters, _ new: RNode.RadioParameters) {
        if new.frequencyHz != old.frequencyHz, let hz = new.frequencyHz { freq = RNode.mHzText(hz) }
        if new.bandwidthHz != old.bandwidthHz, let bw = new.bandwidthHz, RNode.RadioParameters.bandwidths.contains(bw) { bandwidth = bw }
        if new.spreadingFactor != old.spreadingFactor, let s = new.spreadingFactor { sf = s }
        if new.codingRate != old.codingRate, let c = new.codingRate { cr = c }
        if new.txPower != old.txPower, let t = new.txPower { power = min(t, link.session.device.maxTxPower ?? 37) }
    }

    private func load(force: Bool = false) {
        let p = link.session.parameters
        guard force || !loaded else { return }
        loaded = true
        if let hz = p.frequencyHz { freq = RNode.mHzText(hz) }
        if let bw = p.bandwidthHz, RNode.RadioParameters.bandwidths.contains(bw) { bandwidth = bw }
        if let s = p.spreadingFactor { sf = s }
        if let c = p.codingRate { cr = c }
        if let t = p.txPower { power = min(t, link.session.device.maxTxPower ?? 37) }
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
