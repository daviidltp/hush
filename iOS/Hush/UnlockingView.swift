import SwiftUI

// MARK: - Abriendo

/// Pantalla mientras se descifra la base: porcentaje dentro de un anillo que avanza con lo que tardó la
/// última vez (con un toque ligero en cada punto), y debajo el paso en el que va.
struct UnlockingView: View {
    let name: String
    let progress: (start: Date, expected: Double, done: Bool)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let steps = ["Comprobando la clave", "Descifrando \u{00AB}%@\u{00BB}", "Abriendo tus contraseñas"]

    var body: some View {
        TimelineView(.animation) { context in
            let fraction = progress.done ? 1 : min(0.95, context.date.timeIntervalSince(progress.start) / max(progress.expected, 0.4))
            let step = progress.done ? 3 : (fraction < 0.25 ? 0 : fraction < 0.75 ? 1 : 2)
            let percent = Int((fraction * 100).rounded(.down))
            VStack(spacing: 28) {
                ZStack {
                    Circle().stroke(Theme.track, lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(Theme.text, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(percent)%")
                        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.text)
                        .contentTransition(.numericText(value: Double(percent)))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: percent)
                }
                // Un toque ligero cada vez que sube un punto.
                .sensoryFeedback(.impact(weight: .light, intensity: 0.45), trigger: percent)
                .frame(width: 104, height: 104)
                .scaleEffect(progress.done && !reduceMotion ? 1.06 : 1)
                .animation(Theme.springBouncy, value: progress.done)

                VStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        Text(Self.steps[index].replacingOccurrences(of: "%@", with: name))
                            .font(index == min(step, 2) ? .headline : .subheadline)
                            .foregroundStyle(index == min(step, 2) ? Theme.text : Theme.textTertiary)
                            .opacity(index < step ? 0.35 : index == min(step, 2) ? 1 : 0.6)
                            .blur(radius: reduceMotion || index == min(step, 2) ? 0 : 1.2)
                    }
                }
                .animation(reduceMotion ? nil : Theme.spring, value: step)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Abriendo \(name)")
    }
}
