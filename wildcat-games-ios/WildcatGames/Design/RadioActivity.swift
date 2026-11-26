import Foundation
import Observation
import WildcatRadioCore

/// A UI-side observer of the radio: counts packets so the status pill can
/// blip when anything is heard. Purely presentational; the models are
/// unchanged (it is one more listener on `Radio`).
@MainActor
@Observable
final class RadioActivity {
    private(set) var packets = 0
    private(set) var lastHeard: Date?

    init(radio: Radio) {
        radio.addListener { [weak self] event in
            guard let self, case .packet = event else { return }
            self.packets &+= 1
            self.lastHeard = Date()
        }
    }
}
