import LanternfallKit
import SpriteKit
import SwiftUI

/// One run: the SpriteKit scene with the SwiftUI HUD and modals on top.
@MainActor
struct GameRunView: View {
    @ObservedObject var model: GameViewModel
    let onRestart: () -> Void

    @State private var scene: GameScene?
    @Environment(\.scenePhase) private var scenePhase

    private var theme: Theme { Theme(model.content.config.palette) }

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()
            if let scene {
                SpriteView(
                    scene: scene,
                    preferredFramesPerSecond: 60,
                    options: [.ignoresSiblingOrder],
                    debugOptions: Self.debugOptions
                )
                .ignoresSafeArea()
            }
            HUDView(state: model.hud, content: model.content, theme: theme, onPause: { model.pause() })
            overlay
        }
        .onAppear {
            if scene == nil {
                scene = GameScene(model: model)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                model.pause()
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch model.phase {
        case .playing:
            EmptyView()
        case .choosingUpgrade:
            LevelUpView(level: model.hud.level, options: model.choices, content: model.content, theme: theme, onChoose: { model.choose($0) })
        case .paused:
            PauseView(theme: theme, onResume: { model.resume() }, onRestart: onRestart)
        case .gameOver, .victory:
            RunEndView(summary: model.summary, theme: theme, onRestart: onRestart)
        }
    }

    private static var debugOptions: SpriteView.DebugOptions {
        #if DEBUG
        return [.showsFPS, .showsNodeCount]
        #else
        return []
        #endif
    }
}
