import UIKit

/// Haptics for the design system. Generators are made once and reused;
/// every call is safe on devices without a Taptic Engine (it does nothing).
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let notify = UINotificationFeedbackGenerator()
    private static let select = UISelectionFeedbackGenerator()

    /// A Geiger-counter tick; `intensity` 0…1.
    static func tick(_ intensity: CGFloat = 0.5) {
        rigid.impactOccurred(intensity: max(0.1, min(1, intensity)))
    }

    /// Button press.
    static func tap() { light.impactOccurred(intensity: 0.7) }

    /// A packet heard.
    static func blip() { soft.impactOccurred(intensity: 0.5) }

    static func thud() { medium.impactOccurred() }

    static func selection() { select.selectionChanged() }

    static func success() { notify.notificationOccurred(.success) }
    static func warning() { notify.notificationOccurred(.warning) }
    static func error() { notify.notificationOccurred(.error) }

    /// Warm up the engines before a hero moment.
    static func prepare() {
        rigid.prepare()
        notify.prepare()
    }
}
