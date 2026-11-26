import AppKit
import BovedaCore
import SwiftUI

/// Ajustes → Navegadores: cómo instalar la extensión y qué navegadores están conectados.
struct BrowserSettings: View {
    @State private var paired = BrowserBridge.paired
    @State private var passkeys = Preferences.passkeysEnabled
    @State private var offerToSave = Preferences.offerToSaveLogins
    @State private var neverSites = Preferences.neverSaveSites

    var body: some View {
        Form {
            Section {
                step("1", L("Abre la carpeta de la extensión.")) {
                    Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([BrowserBridge.extensionFolder.appending(path: "chromium")]) }
                }
                step("2", L("Chrome, Brave, Edge, Arc o Helium: ve a «extensiones», activa el «modo de desarrollador» y pulsa «Cargar descomprimida». Elige la carpeta «chromium».")) {
                    EmptyView()
                }
                step("3", L("Firefox o Zen: en about:config pon xpinstall.signatures.required en false. Después arrastra «Hush.xpi» a la ventana del navegador.")) {
                    EmptyView()
                }
                step("4", L("Abre la extensión y pulsa «Conectar con Hush». Hush te pedirá permiso una vez por navegador.")) {
                    EmptyView()
                }
            } header: {
                Text("Instalar la extensión")
            } footer: {
                Text("En las webs, al pulsar en el campo de usuario o contraseña salen tus cuentas de esa web. ⇧⌘L rellena con la última que usaste. Si la cuenta tiene 2FA, el código queda copiado.")
                    .font(.ui(11)).foregroundStyle(Theme.textTertiary)
            }

            Section {
                Toggle("Guardar y usar claves de acceso (passkeys) con Hush", isOn: $passkeys)
                    .onChange(of: passkeys) { Preferences.passkeysEnabled = passkeys }
            } footer: {
                Text("Apagado (lo normal), las claves de acceso las da tu Mac o el navegador y la extensión no se mete. Encendido, cuando una web te ofrezca crear una clave de acceso o entrar con ella, Hush lo hará con la clave guardada en tu base (te pedirá confirmación cada vez); se guardan en el formato de las apps KeePass, así que también sirven en el móvil. El cambio se nota al recargar la web.")
                    .font(.ui(11)).foregroundStyle(Theme.textTertiary)
            }

            Section {
                Toggle("Ofrecer guardar contraseñas nuevas", isOn: $offerToSave)
                    .onChange(of: offerToSave) { Preferences.offerToSaveLogins = offerToSave }
            } footer: {
                Text("Cuando entres o te registres en una web con una cuenta que Hush no tiene, la extensión te ofrecerá guardarla; si ya la tienes con otra contraseña, actualizarla. Apagado, la extensión no mira lo que escribes.")
                    .font(.ui(11)).foregroundStyle(Theme.textTertiary)
            }

            Section {
                if neverSites.isEmpty {
                    Text("Ninguna todavía.").foregroundStyle(Theme.textSecondary)
                }
                ForEach(neverSites, id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        Button("Quitar") {
                            Preferences.neverSaveSites.removeAll { $0 == site }
                            neverSites = Preferences.neverSaveSites
                        }
                        .help(L("Volver a ofrecer guardar en \(site)"))
                    }
                }
            } header: {
                Text("No preguntar en estas webs")
            } footer: {
                Text("Webs en las que pulsaste «No preguntar en esta web». Si quitas una, Hush volverá a ofrecer guardar ahí.")
                    .font(.ui(11)).foregroundStyle(Theme.textTertiary)
            }
            .disabled(!offerToSave)

            Section("Navegadores conectados") {
                if paired.isEmpty {
                    Text("Ninguno todavía.").foregroundStyle(Theme.textSecondary)
                }
                ForEach(paired.keys.sorted(), id: \.self) { client in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(paired[client] ?? L("Navegador"))
                            Text(L("Código \(BrowserBridge.code(for: client))")).font(.ui(11)).foregroundStyle(Theme.textTertiary)
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
        .onAppear {
            paired = BrowserBridge.paired
            neverSites = Preferences.neverSaveSites
        }
        // La extensión puede añadir webs con la ventana de Ajustes abierta.
        .onReceive(NotificationCenter.default.publisher(for: BrowserBridge.neverSaveChanged)) { _ in
            neverSites = Preferences.neverSaveSites
        }
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
