import SwiftUI
import UIKit

/// Parses "#RRGGBB" / "#RRGGBBAA" colours from the JSON palette.
enum HexColor {
    struct Components {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    /// Unparseable strings come back magenta so they're easy to spot.
    static func components(_ hex: String) -> Components {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        guard let value = UInt64(digits, radix: 16), digits.count == 6 || digits.count == 8 else {
            return Components(red: 1, green: 0, blue: 1, alpha: 1)
        }
        let rgba = digits.count == 8 ? value : (value << 8) | 0xFF
        return Components(
            red: Double((rgba >> 24) & 0xFF) / 255,
            green: Double((rgba >> 16) & 0xFF) / 255,
            blue: Double((rgba >> 8) & 0xFF) / 255,
            alpha: Double(rgba & 0xFF) / 255
        )
    }
}

extension UIColor {
    convenience init(hex: String) {
        let c = HexColor.components(hex)
        self.init(red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.alpha))
    }
}

extension Color {
    init(hex: String) {
        let c = HexColor.components(hex)
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }
}
