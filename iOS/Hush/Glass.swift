import SwiftUI

// Componentes base del iPhone. El cristal (Liquid Glass de iOS 26) va solo en lo que flota encima del
// contenido: botones, barras, avisos y hojas. El contenido (listas, campos) usa rellenos sólidos de Theme,
// como en el Mac. iOS ya cambia el cristal por un gris sólido con «Reducir transparencia».

/// Fondo de las pantallas: casi negro (o blanco) con una luz suave arriba, para que el cristal se note.
struct HushBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.glow, .clear], center: .init(x: 0.15, y: -0.05), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Theme.glow.opacity(0.6), .clear], center: .init(x: 1.1, y: 1.05), startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

extension Theme {
    /// Luz del fondo.
    static let glow = dynamic(light: 0xEDEDED, dark: 0x262626)
}

/// Botón principal: píldora sólida (blanca en oscuro, negra en claro), como el del Mac.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.onPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Capsule().fill(Theme.primary))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .contentShape(Capsule())
            .animation(.spring(response: 0.2, dampingFraction: 1), value: configuration.isPressed)
    }
}

/// Botón redondo de cristal con un símbolo (atrás, añadir, copiar…).
struct GlassIconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// Tarjeta sólida con filas separadas por una línea fina (detalle, editor, ajustes).
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous).fill(Theme.backgroundSubtle))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
    }
}

/// Línea fina entre filas de una tarjeta.
struct RowDivider: View {
    var inset: CGFloat = 16
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1 / UIScreen.main.scale).padding(.leading, inset)
    }
}

/// Título pequeño encima de una tarjeta.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.top, 8)
    }
}

/// Avatar redondeado con la inicial (o el icono propio) de la entrada.
struct EntryAvatar: View {
    let title: String
    var icon: UIImage? = nil
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Theme.fill)
            if let icon {
                Image(uiImage: icon).resizable().scaledToFit().padding(size * 0.18)
            } else {
                Text(String(title.trimmingCharacters(in: .whitespaces).first ?? "•").uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Píldora de filtro (grupos). La elegida va en sólido, como el botón principal.
struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.onPrimary : Theme.textSecondary)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Capsule().fill(selected ? Theme.primary : Theme.fill))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Barra fina de fortaleza o de progreso.
struct MeterBar: View {
    let fraction: Double
    var tint: Color = Theme.green

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill)
                Capsule().fill(tint).frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 5)
        .animation(Theme.spring, value: fraction)
    }
}

/// Anillo que se vacía con los segundos que le quedan al código 2FA.
struct CountdownRing: View {
    let fraction: Double
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            Circle().stroke(Theme.fill, lineWidth: 3)
            Circle().trim(from: 0, to: fraction)
                .stroke(fraction < 0.2 ? Theme.red : Theme.text, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.linear(duration: 1), value: fraction)
    }
}

// MARK: - Aviso flotante («Copiada»)

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let symbol: String
    let message: String
}

/// Aviso de cristal que entra desde abajo con un muelle y se va solo.
struct ToastHost: ViewModifier {
    @Binding var toast: Toast?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.symbol).font(.subheadline.weight(.semibold))
                    Text(toast.message).font(.subheadline.weight(.medium))
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 18)
                .frame(height: 46)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 96)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                .id(toast.id)
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(Theme.spring) { self.toast = nil }
                }
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : Theme.springBouncy, value: toast)
    }
}

extension View {
    func toast(_ toast: Binding<Toast?>) -> some View { modifier(ToastHost(toast: toast)) }
}
