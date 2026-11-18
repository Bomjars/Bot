import LanternfallKit
import SwiftUI

/// Pick 1 of 3 upgrades. The simulation stays frozen until a card is tapped.
struct LevelUpView: View {
    let level: Int
    let options: [UpgradeOption]
    let content: GameContent
    let theme: Theme
    let onChoose: (UpgradeOption) -> Void

    var body: some View {
        ModalPanel(theme: theme) {
            Text("LEVEL UP")
                .font(Theme.font(30, weight: .heavy))
                .foregroundStyle(theme.light)
            Text("Level \(level) · choose a stolen blessing")
                .font(Theme.font(13, weight: .regular))
                .foregroundStyle(theme.text.opacity(0.8))
            ForEach(options) { option in
                Button {
                    onChoose(option)
                } label: {
                    UpgradeCard(info: UpgradeInfo(option: option, content: content), theme: theme)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Display text for one option, looked up from content.
struct UpgradeInfo {
    let title: String
    let badge: String
    let detail: String
    let colorHex: String

    init(option: UpgradeOption, content: GameContent) {
        let levelBadge = "LV \(option.fromLevel) → \(option.toLevel)"
        switch option.kind {
        case .weapon:
            let weapon = content.weapon(id: option.itemID)
            title = weapon?.name ?? option.itemID
            badge = option.isNew ? "NEW WEAPON" : levelBadge
            detail = weapon.map { $0.levels[min(option.toLevel, $0.maxLevel) - 1].description } ?? ""
            colorHex = weapon?.color ?? content.config.palette.light
        case .passive:
            let passive = content.passive(id: option.itemID)
            title = passive?.name ?? option.itemID
            badge = option.isNew ? "NEW" : levelBadge
            detail = passive?.description ?? ""
            colorHex = passive?.color ?? content.config.palette.light
        case .heal:
            title = "Holy Water"
            badge = "HEAL"
            detail = "Restore \(Int(content.config.upgrades.fallbackHealAmount)) HP."
            colorHex = content.config.palette.danger
        }
    }
}

private struct UpgradeCard: View {
    let info: UpgradeInfo
    let theme: Theme

    var body: some View {
        let color = Color(hex: info.colorHex)
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color)
                .frame(width: 40, height: 40)
                .overlay(
                    Text(String(info.title.prefix(1)))
                        .font(Theme.font(20, weight: .heavy))
                        .foregroundStyle(theme.background)
                )
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(info.title)
                        .font(Theme.font(16, weight: .heavy))
                        .foregroundStyle(theme.text)
                    Spacer()
                    Text(info.badge)
                        .font(Theme.font(10))
                        .foregroundStyle(color)
                }
                Text(info.detail)
                    .font(Theme.font(12, weight: .regular))
                    .foregroundStyle(theme.text.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(theme.backgroundAlt))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.6), lineWidth: 1.5))
        .contentShape(Rectangle())
    }
}
