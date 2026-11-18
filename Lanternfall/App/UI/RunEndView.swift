import SwiftUI

/// Shown on death or when the timer runs out. Phase 3 turns this into the
/// full results screen (gold, boss) and routes back to camp.
struct RunEndView: View {
    let summary: RunSummary
    let theme: Theme
    let onRestart: () -> Void

    var body: some View {
        ModalPanel(theme: theme) {
            Text(summary.victory ? "THE GATE OPENS" : "DRAGGED BACK DOWN")
                .font(Theme.font(24, weight: .heavy))
                .foregroundStyle(summary.victory ? theme.light : theme.danger)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                StatRow(label: "Time survived", value: String(format: "%d:%02d", summary.secondsSurvived / 60, summary.secondsSurvived % 60), theme: theme)
                StatRow(label: "Demons slain", value: "\(summary.kills)", theme: theme)
                StatRow(label: "Level reached", value: "\(summary.level)", theme: theme)
            }

            if !summary.damage.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DAMAGE")
                        .font(Theme.font(11))
                        .foregroundStyle(theme.text.opacity(0.6))
                    ForEach(summary.damage) { weapon in
                        StatRow(label: weapon.name, value: "\(weapon.damage)", theme: theme)
                    }
                }
            }

            Button("Try Again", action: onRestart)
                .buttonStyle(LanternButtonStyle(theme: theme))
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    let theme: Theme

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(theme.text.opacity(0.8))
            Spacer()
            Text(value)
                .foregroundStyle(theme.text)
                .monospacedDigit()
        }
        .font(Theme.font(14))
    }
}
