import BovedaCore
import SwiftUI

/// Fortaleza de una contraseña en palabras y en fracción, para las barras.
struct PasswordStrengthInfo {
    let fraction: Double
    let label: String

    init(_ password: String) {
        let strength = PasswordStrength.of(password)
        fraction = strength.fraction
        label = strength.label
    }
}

/// Generador: contraseña en grande con copiar y regenerar, y las opciones debajo.
struct GeneratorPanel: View {
    @Environment(AppModel.self) private var model
    @Binding var value: String
    @State private var options = Preferences.generator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 14) {
                Text(value)
                    .font(.mono(.title3, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .contentTransition(.opacity)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    GlassIconButton(symbol: "doc.on.doc", label: "Copiar", size: 44) { model.copy(value, label: "Contraseña") }
                    GlassIconButton(symbol: "arrow.clockwise", label: "Otra", size: 44) { regenerate() }
                }
                let entropy = PasswordGenerator.entropy(options)
                let fraction = PasswordStrength.of(bits: entropy).fraction
                HStack(spacing: 8) {
                    MeterBar(fraction: fraction, tint: Theme.strengthColor(fraction))
                    Text("\(Int(entropy)) bits").font(.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary).fixedSize()
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous).fill(Theme.backgroundSubtle))

            Picker("Tipo", selection: $options.usePassphrase) {
                Text("Aleatoria").tag(false)
                Text("Frase").tag(true)
            }
            .pickerStyle(.segmented)

            Card {
                if options.usePassphrase {
                    stepperRow("Palabras", value: $options.wordCount, range: 3...10)
                    RowDivider()
                    toggleRow("Mayúscula inicial", $options.capitalize)
                    RowDivider()
                    toggleRow("Añadir un número", $options.addNumber)
                    RowDivider()
                    HStack {
                        Text("Separador")
                        Spacer()
                        Picker("Separador", selection: $options.separator) {
                            Text("Guion").tag("-")
                            Text("Punto").tag(".")
                            Text("Espacio").tag(" ")
                            Text("Guion bajo").tag("_")
                        }
                        .labelsHidden()
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Longitud")
                            Spacer()
                            Text("\(options.length)").monospacedDigit().foregroundStyle(Theme.textSecondary)
                        }
                        Slider(value: Binding(get: { Double(options.length) }, set: { options.length = Int($0) }), in: 8...64, step: 1)
                            .accessibilityValue("\(options.length) caracteres")
                    }
                    .padding(16)
                    RowDivider()
                    toggleRow("Mayúsculas (A-Z)", $options.uppercase)
                    RowDivider()
                    toggleRow("Minúsculas (a-z)", $options.lowercase)
                    RowDivider()
                    toggleRow("Números (0-9)", $options.digits)
                    RowDivider()
                    toggleRow("Símbolos (!@#…)", $options.symbols)
                    RowDivider()
                    toggleRow("Evitar parecidos (l, 1, O, 0)", $options.avoidAmbiguous)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: options.length)
        .onChange(of: options) { _, new in
            Preferences.generator = new
            regenerate()
        }
        .onAppear { if value.isEmpty { regenerate() } }
    }

    private func regenerate() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
            value = PasswordGenerator.generate(options)
        }
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(title, isOn: binding)
            .tint(Theme.green)
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
    }

    private func stepperRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper("\(title): \(value.wrappedValue)", value: value, in: range)
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
    }
}

/// Pestaña Generador.
struct GeneratorScreen: View {
    @State private var value = ""

    var body: some View {
        ScrollView {
            GeneratorPanel(value: $value)
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 120)
        }
        .background(HushBackground())
        .navigationTitle("Generador")
    }
}

/// Hoja del generador desde el editor: sube desde abajo y se cierra arrastrando.
struct GeneratorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    let use: (String) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    GeneratorPanel(value: $value)
                    Button("Usar contraseña") {
                        use(value)
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 24)
            }
            .navigationTitle("Generador")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar", systemImage: "xmark") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }
}
