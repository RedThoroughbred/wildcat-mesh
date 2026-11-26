import StoreKit
import SwiftUI
import WildcatRadioCore

extension View {
    /// Asks for an App Store rating at a good moment (`ReviewPrompt`).
    func reviewPrompt() -> some View { modifier(ReviewPromptModifier()) }
}

/// The good moments: the first message another node confirms (Meshtastic or
/// MeshCore), or a fox found (Den hunt, solo hunt, MeshCore hunt, Daily Fox).
/// The prompt waits until the app is in front and nothing is running.
private struct ReviewPromptModifier: ViewModifier {
    @Environment(Radio.self) private var radio
    @Environment(MeshCoreLink.self) private var meshcore
    @Environment(MessageStore.self) private var messages
    @Environment(MeshCoreStore.self) private var meshcoreStore
    @Environment(HuntModel.self) private var hunt
    @Environment(SoloHunt.self) private var solo
    @Environment(MeshCoreHunt.self) private var meshcoreHunt
    @Environment(PhoneReferee.self) private var referee
    @Environment(WalkRecorder.self) private var walker
    @Environment(ExploreModel.self) private var explore
    @Environment(\.scenePhase) private var phase
    @Environment(\.requestReview) private var requestReview
    @AppStorage(ReviewPrompt.lastAskedKey) private var askedVersion = ""
    @State private var due = false

    func body(content: Content) -> some View {
        content
            // Delivery counts leave out practice radios.
            .onChange(of: messages.deliveredCount) { due = true }
            .onChange(of: meshcoreStore.confirmedCount) { due = true }
            .onChange(of: hunt.stage) { _, stage in
                if case .found = stage, radio.source != .practice { due = true }
            }
            .onChange(of: solo.finished != nil) { _, found in
                if found, radio.source != .practice { due = true }
            }
            .onChange(of: meshcoreHunt.found != nil) { _, found in
                if found, !meshcore.isDemo { due = true }
            }
            .onChange(of: explore.todayRun?.found != nil) { _, found in
                if found { due = true }
            }
            .task(id: Gate(due: due, active: phase == .active, busy: busy)) {
                guard due, phase == .active, !busy else { return }
                try? await Task.sleep(for: ReviewPrompt.delay)
                guard !Task.isCancelled else { return }
                due = false
                let version = ReviewPrompt.appVersion
                guard ReviewPrompt.shouldAsk(lastAsked: askedVersion, version: version, busy: busy) else { return }
                askedVersion = version ?? ""
                requestReview()
            }
    }

    /// A hunt, a hosted hunt, a coverage walk or a Daily Fox under way.
    private var busy: Bool {
        ReviewPrompt.isHunting(hunt.stage) || solo.isActive || meshcoreHunt.isActive || referee.isHosting
            || walker.isWalking || explore.tracker != nil
    }

    private struct Gate: Equatable {
        var due: Bool
        var active: Bool
        var busy: Bool
    }
}
