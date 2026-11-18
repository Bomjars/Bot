import SwiftUI

struct PauseView: View {
    let theme: Theme
    let onResume: () -> Void
    let onRestart: () -> Void

    var body: some View {
        ModalPanel(theme: theme) {
            Text("PAUSED")
                .font(Theme.font(30, weight: .heavy))
                .foregroundStyle(theme.light)
            Button("Resume", action: onResume)
                .buttonStyle(LanternButtonStyle(theme: theme))
            Button("Restart Run", action: onRestart)
                .buttonStyle(LanternButtonStyle(theme: theme, prominent: false))
        }
    }
}
