import LanternfallKit
import SwiftUI

/// Loads content once, then hosts one run at a time. Phase 4 puts the main
/// menu, character select and level select in front of this.
@MainActor
struct RootView: View {
    private enum LoadState {
        case ready(GameContent)
        case failed(String)
    }

    private struct RunSession {
        let id = UUID()
        let model: GameViewModel
    }

    @State private var loadState: LoadState = RootView.loadContent()
    @State private var run: RunSession?

    var body: some View {
        switch loadState {
        case .failed(let message):
            ContentErrorView(message: message)
        case .ready(let content):
            if let run {
                GameRunView(model: run.model, onRestart: { startRun(content) })
                    .id(run.id)
            } else {
                Color(hex: content.config.palette.background)
                    .ignoresSafeArea()
                    .onAppear { startRun(content) }
            }
        }
    }

    private func startRun(_ content: GameContent) {
        do {
            let simulation = try GameSimulation(
                content: content,
                levelID: content.config.startup.levelID,
                characterID: content.config.startup.characterID,
                seed: UInt64.random(in: 0...UInt64.max)
            )
            run = RunSession(model: GameViewModel(simulation: simulation))
        } catch {
            loadState = .failed(String(describing: error))
        }
    }

    private static func loadContent() -> LoadState {
        do {
            return .ready(try GameContent.loadBundled())
        } catch {
            return .failed(String(describing: error))
        }
    }
}

private struct ContentErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Text("Couldn't load game data")
                .font(.headline)
            Text(message)
                .font(.system(.footnote, design: .monospaced))
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
