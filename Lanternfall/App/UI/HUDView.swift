import LanternfallKit
import SwiftUI

/// Top-of-screen HUD: XP bar, level, timer, kills, pause, owned items.
/// The HP bar lives in the scene, under the player sprite.
struct HUDView: View {
    let state: HUDState
    let content: GameContent
    let theme: Theme
    let onPause: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            XPBar(fraction: state.xpFraction, theme: theme)
                .frame(height: 10)

            HStack {
                Text("LV \(state.level)")
                    .foregroundStyle(theme.lightSoft)
                Spacer()
                Text(Self.clock(state.elapsedSeconds))
                    .monospacedDigit()
                Spacer()
                Label("\(state.kills)", systemImage: "flame.fill")
                    .monospacedDigit()
                Button(action: onPause) {
                    Image(systemName: "pause.fill")
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(theme.backgroundAlt.opacity(0.85)))
                }
                .accessibilityLabel("Pause")
            }
            .font(Theme.font(15))
            .foregroundStyle(theme.text)

            HStack(spacing: 4) {
                ForEach(state.weapons, id: \.id) { item in
                    ItemBadge(
                        name: content.weapon(id: item.id)?.name ?? item.id,
                        level: item.level,
                        color: Color(hex: content.weapon(id: item.id)?.color ?? content.config.palette.light),
                        theme: theme
                    )
                }
                if !state.passives.isEmpty {
                    Rectangle()
                        .fill(theme.text.opacity(0.25))
                        .frame(width: 1, height: 20)
                        .padding(.horizontal, 2)
                }
                ForEach(state.passives, id: \.id) { item in
                    ItemBadge(
                        name: content.passive(id: item.id)?.name ?? item.id,
                        level: item.level,
                        color: Color(hex: content.passive(id: item.id)?.color ?? content.config.palette.light),
                        theme: theme
                    )
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct XPBar: View {
    let fraction: Double
    let theme: Theme

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.backgroundAlt.opacity(0.9))
                Capsule()
                    .fill(LinearGradient(colors: [theme.light, theme.lightSoft], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, proxy.size.width * fraction))
            }
            .overlay(Capsule().stroke(theme.lightSoft.opacity(0.35), lineWidth: 1))
        }
        .accessibilityElement()
        .accessibilityLabel("Experience")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

/// Placeholder item icon: coloured tile with the item's initial and level.
struct ItemBadge: View {
    let name: String
    let level: Int
    let color: Color
    let theme: Theme

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(color.opacity(0.9))
            .frame(width: 26, height: 26)
            .overlay(
                Text(String(name.prefix(1)))
                    .font(Theme.font(13, weight: .heavy))
                    .foregroundStyle(theme.background)
            )
            .overlay(alignment: .bottomTrailing) {
                Text("\(level)")
                    .font(Theme.font(9))
                    .foregroundStyle(theme.text)
                    .padding(.horizontal, 2)
                    .background(theme.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                    .offset(x: 3, y: 3)
            }
            .accessibilityElement()
            .accessibilityLabel("\(name) level \(level)")
    }
}
