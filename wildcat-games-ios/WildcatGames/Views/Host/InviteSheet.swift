import SwiftUI
import WildcatRadioCore

/// "Join FOX7?" after scanning a host's QR code or opening their link.
struct InviteSheet: View {
    let invite: HuntInvite
    var onJoined: () -> Void
    @Environment(InviteHandler.self) private var invites
    @Environment(Radio.self) private var radio
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.stack) {
            HStack(spacing: 12) {
                IconTile(symbol: "scope", size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        CardLabel("Fox Hunt invite")
                        NetworkTag(.meshtastic)
                    }
                    Text(invite.code).font(.system(.largeTitle, design: .monospaced, weight: .light)).foregroundStyle(Theme.textPrimary)
                }
            }
            MetaLine("Hosted by \(radio.session.label(for: NodeNum(invite.host))). The fox is \(radio.session.label(for: invite.foxNode)).",
                     raw: "channel \(invite.channelName)")
            if let plan = invites.plan {
                Notice(text: plan)
            }
            switch invites.step {
            case .working(let s): ProgressView(s).tint(Theme.textSecondary)
            case .failed(let s): ToastBanner(text: s, kind: .danger)
            default: EmptyView()
            }
            Spacer()
            Button {
                Task {
                    await invites.accept()
                    if invites.step == .joined {
                        onJoined()
                        dismiss()
                    }
                }
            } label: {
                Label("Join the hunt", systemImage: "flag.checkered").frame(maxWidth: .infinity)
            }
            .buttonStyle(.fieldPrimary)
            .disabled(!radio.isReady || { if case .working = invites.step { return true } else { return false } }())
            Button("Not now") { invites.pending = nil }
                .buttonStyle(.field(.quiet, .regular))
                .frame(maxWidth: .infinity)
        }
        .padding(Theme.Space.edge)
        .screen()
        .presentationDetents([.medium, .large])
    }
}
