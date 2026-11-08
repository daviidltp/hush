import AppKit
import SwiftUI

/// Ajustes → Navegadores: cómo instalar la extensión y qué navegadores están conectados.
struct BrowserSettings: View {
    @State private var paired = BrowserBridge.paired

    var body: some View {
        Form {
            Section {
                step("1", "Abre la carpeta de la extensión.") {
                    Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([BrowserBridge.extensionFolder.appending(path: "chromium")]) }
                }
                step("2", "Chrome, Brave, Edge o Arc: ve a «extensiones», activa el «modo de desarrollador» y pulsa «Cargar descomprimida». Elige la carpeta «chromium».") {
                    EmptyView()
                }
                step("3", "Firefox o Zen: en about:config pon xpinstall.signatures.required en false. Después arrastra «Hush.xpi» a la ventana del navegador.") {
                    EmptyView()
                }
                step("4", "Abre la extensión y pulsa «Conectar con Hush». Hush te pedirá permiso una vez por navegador.") {
                    EmptyView()
                }
            } header: {
                Text("Instalar la extensión")
            } footer: {
                Text("En las webs, al pulsar en el campo de usuario o contraseña salen tus cuentas de esa web. ⇧⌘L rellena con la última que usaste. Si la cuenta tiene 2FA, el código queda copiado.")
                    .font(.ui(11)).foregroundStyle(Theme.textTertiary)
            }

            Section("Navegadores conectados") {
                if paired.isEmpty {
                    Text("Ninguno todavía.").foregroundStyle(Theme.textSecondary)
                }
                ForEach(paired.keys.sorted(), id: \.self) { client in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(paired[client] ?? "Navegador")
                            Text("Código \(BrowserBridge.code(for: client))").font(.ui(11)).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Button("Desconectar") {
                            BrowserBridge.paired[client] = nil
                            paired = BrowserBridge.paired
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { paired = BrowserBridge.paired }
    }

    private func step<Accessory: View>(_ number: String, _ text: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number).font(.ui(12, .semibold)).foregroundStyle(Theme.textTertiary).frame(width: 14)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            accessory()
        }
    }
}
