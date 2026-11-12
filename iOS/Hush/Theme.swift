import SwiftUI
import UIKit

/// Tokens de diseño del iPhone. Son los mismos valores que `Sources/Boveda/Theme.swift` del Mac
/// (monocromo, rellenos suaves y todo muy redondeado); si cambias uno allí, cámbialo aquí.
enum Theme {
    // Fondos
    static let background = dynamic(light: 0xFFFFFF, dark: 0x050505)
    static let backgroundSubtle = dynamic(light: 0xF7F7F7, dark: 0x111111)
    static let fill = dynamic(light: 0xF2F2F2, dark: 0x181818)
    static let selected = dynamic(light: 0xE8E8E8, dark: 0x232526)
    static let field = dynamic(light: 0xF4F4F4, dark: 0x111111)
    static let sheet = dynamic(light: 0xFFFFFF, dark: 0x101213)
    // Bordes
    static let border = dynamic(light: 0xECECEC, dark: 0x242424)
    static let borderStrong = dynamic(light: 0xD4D4D4, dark: 0x383838)
    // Texto
    static let text = dynamic(light: 0x0D0D0D, dark: 0xFAFAFA)
    static let textSecondary = dynamic(light: 0x595959, dark: 0xB4B4B4)
    static let textTertiary = dynamic(light: 0x6D6D6D, dark: 0x999999)
    // Botón principal (negro en claro, blanco en oscuro)
    static let primary = dynamic(light: 0x0D0D0D, dark: 0xFFFFFF)
    static let onPrimary = dynamic(light: 0xFFFFFF, dark: 0x050505)
    // Estados
    static let blue = dynamic(light: 0x0A6CFF, dark: 0x74B9E8)
    static let green = dynamic(light: 0x1A7F37, dark: 0x62C28A)
    static let amber = dynamic(light: 0x8F5F00, dark: 0xF1B35B)
    static let red = dynamic(light: 0xCF222E, dark: 0xF27D78)

    static let radius: CGFloat = 12
    static let radiusLarge: CGFloat = 22
    /// Margen lateral de las pantallas.
    static let gutter: CGFloat = 16

    /// Muelles. Sin rebote por defecto; con un poco de rebote solo tras un gesto con impulso.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 1)
    static let springBouncy = Animation.spring(response: 0.4, dampingFraction: 0.8)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    static func strengthColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.3: return red
        case ..<0.5: return amber
        default: return green
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

extension Font {
    /// Código 2FA y contraseñas: monoespaciada, como en el Mac.
    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced).weight(weight)
    }
}
