import LanternfallKit
import SwiftUI

/// SwiftUI colours and fonts derived from the JSON palette.
struct Theme {
    let background: Color
    let backgroundAlt: Color
    let light: Color
    let lightSoft: Color
    let shadow: Color
    let danger: Color
    let text: Color

    init(_ palette: PaletteConfig) {
        background = Color(hex: palette.background)
        backgroundAlt = Color(hex: palette.backgroundAlt)
        light = Color(hex: palette.light)
        lightSoft = Color(hex: palette.lightSoft)
        shadow = Color(hex: palette.enemyShadow)
        danger = Color(hex: palette.danger)
        text = Color(hex: palette.text)
    }

    /// Placeholder until the pixel font lands (Phase 4).
    static func font(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct LanternButtonStyle: ButtonStyle {
    let theme: Theme
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(18, weight: .heavy))
            .foregroundStyle(prominent ? theme.background : theme.text)
            .frame(maxWidth: 260)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(prominent ? theme.light : theme.backgroundAlt)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(theme.lightSoft.opacity(prominent ? 0 : 0.4), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// Dimmed full-screen backdrop with a centred panel.
struct ModalPanel<Content: View>: View {
    let theme: Theme
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                content
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(theme.background.opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(theme.light.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 16)
        }
    }
}
