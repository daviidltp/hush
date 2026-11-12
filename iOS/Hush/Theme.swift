import SwiftUI
import UIKit

/// Tokens de diseño del iPhone: la línea del Mac (`Sources/Boveda/Theme.swift`, monocromo y muy redondeado)
/// con la paleta oscura de Budky móvil (fondo negro, superficie #121212, sobre-superficie #2A2A2A), que da
/// más contraste entre el fondo y las tarjetas en una pantalla de móvil.
enum Theme {
    // Fondos
    static let background = dynamic(light: 0xFFFFFF, dark: 0x000000)
    static let backgroundSubtle = dynamic(light: 0xF4F4F4, dark: 0x121212)
    static let fill = dynamic(light: 0xE9E9E9, dark: 0x2A2A2A)
    static let selected = dynamic(light: 0xE4E4E4, dark: 0x1C1C1C)
    static let field = dynamic(light: 0xF4F4F4, dark: 0x121212)
    static let sheet = dynamic(light: 0xFFFFFF, dark: 0x000000)
    // Bordes
    static let border = dynamic(light: 0xECECEC, dark: 0x181818)
    static let borderStrong = dynamic(light: 0xD4D4D4, dark: 0x383838)
    // Texto
    static let text = dynamic(light: 0x0D0D0D, dark: 0xFFFFFF)
    static let textSecondary = dynamic(light: 0x595959, dark: 0xBBBBBB)
    static let textTertiary = dynamic(light: 0x6D6D6D, dark: 0x888888)
    // Botón principal (negro en claro, blanco en oscuro)
    static let primary = dynamic(light: 0x0D0D0D, dark: 0xFFFFFF)
    static let onPrimary = dynamic(light: 0xFFFFFF, dark: 0x000000)
    /// Pista de interruptores y barras apagadas.
    static let track = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.08) })
    // Estados
    static let blue = dynamic(light: 0x0A6CFF, dark: 0x257FF9)
    static let green = dynamic(light: 0x1A7F37, dark: 0x34D399)
    static let amber = dynamic(light: 0x8F5F00, dark: 0xEAB308)
    static let red = dynamic(light: 0xCF222E, dark: 0xF87171)

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
