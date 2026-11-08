import AppKit
import SwiftUI

/// Tokens de diseño inspirados en Grok: monocromo, rellenos suaves en vez de bordes, todo muy redondeado.
/// La tipografía es la del sistema (SF Pro) para que se sienta nativo.
enum Theme {
    // Fondos. El modo oscuro usa la paleta de Budky Marketing (fondo casi negro, superficies #111/#181818).
    static let background = dynamic(light: 0xFFFFFF, dark: 0x050505)
    static let backgroundSubtle = dynamic(light: 0xF7F7F7, dark: 0x111111)
    static let fill = dynamic(light: 0xF2F2F2, dark: 0x181818)
    static let hover = dynamic(light: 0xF0F0F0, dark: 0x161616)
    static let selected = dynamic(light: 0xE8E8E8, dark: 0x232526)
    static let field = dynamic(light: 0xF4F4F4, dark: 0x111111)
    static let sheet = dynamic(light: 0xFFFFFF, dark: 0x101213)
    // Bordes (finos y suaves)
    static let border = dynamic(light: 0xECECEC, dark: 0x242424)
    static let borderStrong = dynamic(light: 0xD4D4D4, dark: 0x383838)
    // Texto
    static let text = dynamic(light: 0x0D0D0D, dark: 0xFAFAFA)
    // En claro, los dos grises pasan de 4,5:1 sobre todos los fondos claros (blanco, subtle y fill).
    static let textSecondary = dynamic(light: 0x595959, dark: 0xB4B4B4)
    static let textTertiary = dynamic(light: 0x6D6D6D, dark: 0x999999)
    // Botón principal (negro en claro, blanco en oscuro)
    static let primary = dynamic(light: 0x0D0D0D, dark: 0xFFFFFF)
    static let onPrimary = dynamic(light: 0xFFFFFF, dark: 0x050505)
    // Estados
    static let blue = dynamic(light: 0x0A6CFF, dark: 0x74B9E8)
    // En claro se usan tonos más oscuros: también son texto (errores, avisos, diferencias) y deben leerse.
    static let green = dynamic(light: 0x1A7F37, dark: 0x62C28A)
    static let amber = dynamic(light: 0x8F5F00, dark: 0xF1B35B)
    static let red = dynamic(light: 0xCF222E, dark: 0xF27D78)

    static let radius: CGFloat = 10
    static let radiusLarge: CGFloat = 16

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
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

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

extension Font {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Componentes base

/// Botón en forma de píldora, como en Grok: principal (relleno negro), secundario (gris suave) o fantasma.
struct GButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        GButtonBody(configuration: configuration, kind: kind, compact: compact)
    }

    private struct GButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let compact: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.ui(compact ? 12 : 13, .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, compact ? 10 : 16)
                .frame(height: compact ? 28 : 34)
                .background(Capsule().fill(background))
                .overlay(Capsule().strokeBorder(kind == .secondary ? Theme.border : .clear))
                .opacity(enabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        var foreground: Color {
            switch kind {
            case .primary: return Theme.onPrimary
            case .danger: return .white
            default: return Theme.text
            }
        }

        var background: Color {
            switch kind {
            case .primary: return hovering ? Theme.primary.opacity(0.85) : Theme.primary
            case .danger: return hovering ? Theme.red.opacity(0.85) : Theme.red
            case .secondary: return hovering ? Theme.hover : Theme.background
            case .ghost: return hovering ? Theme.hover : .clear
            }
        }
    }
}

/// Botón redondo de icono, para acciones de campo.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 30
    var tint: Color = Theme.textSecondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : tint)
                .frame(width: size, height: size)
                .background(Circle().fill(hovering ? Theme.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Atajo de teclado dibujado como una tecla.
struct Kbd: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.ui(11, .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill))
    }
}

/// Campo de texto con relleno gris suave y esquinas muy redondeadas, como el input de Grok.
struct GField<Content: View>: View {
    var focused: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .textFieldStyle(.plain)
            .font(.ui(13))
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Theme.borderStrong : .clear))
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// Etiqueta pequeña tipo píldora.
struct Badge: View {
    let text: String
    var tint: Color = Theme.textSecondary
    var body: some View {
        Text(text)
            .font(.ui(11, .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Theme.fill))
    }
}

/// Avatar redondeado con la inicial de la entrada.
struct EntryAvatar: View {
    let title: String
    var size: CGFloat = 28

    var body: some View {
        Text(String(title.trimmingCharacters(in: .whitespaces).first ?? "•").uppercased())
            .font(.ui(size * 0.44, .semibold))
            .foregroundStyle(Theme.text)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Theme.fill))
    }
}

extension View {
    func hairline(_ edge: Edge) -> some View {
        overlay(alignment: edge.alignment) {
            Rectangle().fill(Theme.border).frame(width: edge.isVertical ? 1 : nil, height: edge.isVertical ? nil : 1)
        }
    }
}

private extension Edge {
    var isVertical: Bool { self == .leading || self == .trailing }
    var alignment: Alignment {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
}
