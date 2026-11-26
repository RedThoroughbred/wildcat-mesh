import SwiftUI
import WildcatRadioCore

/// Hunt for 2–3 friends (Small Play 2): one screen that follows the game on this phone.
/// Set up → hide the pieces → (hider) the live round / (hunter) the board → round over → swap.
struct HuntGameView: View {
    @Environment(GamePlay.self) private var play
    @Environment(\.tabRouter) private var router

    var body: some View {
        @Bindable var play = play
        Group {
            if let round = play.round {
                switch (round.role, round.stage) {
                case (.hider, .hiding): HideWalkView()
                case (.hider, .live): GameHostBoardView()
                case (.hunter, .hiding), (.hunter, .live): GameBoardView()
                case (_, .over): GameResultsView()
                }
            } else {
                HuntSetupView()
            }
        }
        .animation(Theme.Motion.settle, value: play.round?.stage)
        .sheet(isPresented: $play.inviteShown) { GameQRSheet() }
        .onAppear { router?.gameScreensShown += 1 }
        .onDisappear { router?.gameScreensShown -= 1 }
    }
}
