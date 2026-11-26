import Foundation
import Observation
import WildcatRadioCore

/// Opens a host's hunt invite (QR code or link): adds the hunt channel to the
/// player's node if it's missing or has a different key, then joins.
@MainActor
@Observable
final class InviteHandler {
    enum Step: Equatable {
        case ready
        case working(String)
        case joined
        case failed(String)
    }

    /// The invite waiting for the player to confirm.
    var pending: HuntInvite?
    /// A Hunt game's invite (Small Play 2) waiting for the player to confirm.
    var pendingGame: HuntGame.Invite?
    private(set) var step: Step = .ready

    private let radio: Radio
    private let hunt: HuntModel
    private let admin: NodeAdmin
    private let games: GamePlay?

    init(radio: Radio, hunt: HuntModel, admin: NodeAdmin, games: GamePlay? = nil) {
        self.radio = radio
        self.hunt = hunt
        self.admin = admin
        self.games = games
    }

    /// True when `link` was a hunt invite or a Hunt game's (it's then waiting for confirmation).
    @discardableResult
    func open(_ link: String) -> Bool {
        if let invite = HuntInvite(link: link) {
            pending = invite
            step = .ready
            return true
        }
        guard Features.smallPlay, games != nil, let invite = HuntGame.Invite(link: link) else { return false }
        pendingGame = invite
        step = .ready
        return true
    }

    /// What joining a Hunt game changes, in words.
    var gamePlan: String? {
        guard let invite = pendingGame else { return nil }
        guard radio.isReady else {
            return "No node connected: you can still hunt with the GPS guide (marked \"guide\"), and claim with the code on each piece's label."
        }
        switch channelChange(channel: invite.channel, name: invite.channelName) {
        case nil: return "Your node already has \(invite.channelName). Joining is one tap."
        case .channel(let i, _, _)?:
            return radio.session.channels[i] == nil
                ? "Adds the \(invite.channelName) channel to your node (slot \(i)), next to your others. Then joins every piece."
                : "Updates your \(invite.channelName) channel to the hider's key. Then joins every piece."
        default: return nil
        }
    }

    /// Joins a Hunt game's round: the hunt channel first when a node is connected (none needed for the guide).
    func acceptGame() async {
        guard let invite = pendingGame, let games else { return }
        if radio.isReady, let change = channelChange(channel: invite.channel, name: invite.channelName) {
            step = .working("Adding \(invite.channelName) to your node…")
            await admin.apply([change], summary: "Hunt channel")
            if case .failed(let why) = admin.status {
                step = .failed(why)
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
        games.join(invite: invite)
        step = .joined
        pendingGame = nil
    }

    /// What joining will change on the player's node, in words.
    var plan: String? {
        guard let invite = pending else { return nil }
        guard radio.isReady else { return "Needs a Meshtastic node: connect it on the Meshtastic tab, then come back to this invite." }
        switch channelChange(for: invite) {
        case nil: return "Your node already has \(invite.channelName). Joining is one tap."
        case .channel(let i, _, _)?:
            return radio.session.channels[i] == nil
                ? "Adds the \(invite.channelName) channel to your node (slot \(i)), next to your others. Then joins."
                : "Updates your \(invite.channelName) channel to the host's key. Then joins."
        default: return nil
        }
    }

    private func channelChange(for invite: HuntInvite) -> NodeAdmin.Change? {
        channelChange(channel: invite.channel, name: invite.channelName)
    }

    private func channelChange(channel: Data, name channelName: String) -> NodeAdmin.Change? {
        let s = radio.session
        let name = channelName.uppercased()
        if let existing = s.channels.values.first(where: { $0.name.uppercased() == name }) {
            if existing.settings.map(ChannelSettings.init)?.psk == ChannelSettings(raw: channel).psk { return nil }
            return .channel(index: existing.index, settings: channel, role: existing.index == 0 ? .primary : .secondary)
        }
        guard let free = (1...7).first(where: { s.channels[$0] == nil }) else { return nil }
        return .channel(index: free, settings: channel, role: .secondary)
    }

    func accept() async {
        guard let invite = pending, radio.isReady else { return }
        if let change = channelChange(for: invite) {
            step = .working("Adding \(invite.channelName) to your node…")
            await admin.apply([change], summary: "Hunt channel")
            if case .failed(let why) = admin.status {
                step = .failed(why)
                return
            }
            // Let the node settle before the first WG message.
            try? await Task.sleep(for: .seconds(3))
        }
        step = .working("Joining \(invite.code)…")
        hunt.join(invite: invite)
        step = .joined
        pending = nil
    }
}
