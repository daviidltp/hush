import AuthenticationServices
import BovedaCore
import SwiftUI

/// Ajustes: base abierta, Face ID, bloqueo automático y portapapeles.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var confirmEmptyBin = false
    @State private var autoFillOn = false

    var body: some View {
        @Bindable var model = model
        Form {
            if let db = model.openDatabase {
                Section("Base abierta") {
                    LabeledContent("Nombre", value: model.vault?.name ?? db.name)
                    LabeledContent("Archivo", value: db.name + ".kdbx")
                    LabeledContent("Ubicación", value: db.location)
                    if let count = model.vault?.root.entryCount(excluding: model.excluded) {
                        LabeledContent("Entradas", value: "\(count)")
                    }
                    if model.saving {
                        LabeledContent("Estado") { Label("Guardando…", systemImage: "arrow.triangle.2.circlepath") }
                    } else if model.unsaved {
                        LabeledContent("Estado") { Text("Sin guardar").foregroundStyle(Theme.red) }
                    }
                }
                .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)
            }

            Section {
                Toggle("Desbloquear con \(model.biometryName)", isOn: $model.faceIDEnabled).tint(Theme.green)
                Picker("Bloquear al salir de la app", selection: $model.autoLockSeconds) {
                    Text("Al momento").tag(0)
                    Text("Tras 1 minuto").tag(60)
                    Text("Tras 5 minutos").tag(300)
                    Text("Tras 15 minutos").tag(900)
                }
            } header: {
                Text("Seguridad")
            } footer: {
                Text("La clave para \(model.biometryName) se guarda cifrada con el chip seguro del iPhone. Si cambian las caras o huellas registradas, hay que volver a escribir la contraseña maestra.")
            }
            .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)

            Section {
                if autoFillOn {
                    Label("Activado", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green)
                } else {
                    Button("Activar autorrelleno", systemImage: "key.viewfinder") {
                        Task {
                            _ = try? await ASSettingsHelper.requestToTurnOnCredentialProviderExtension()
                            await refreshAutoFill()
                        }
                    }
                }
            } header: {
                Text("Autorrelleno")
            } footer: {
                Text("Rellena contraseñas y códigos 2FA en Safari y en otras apps desde la llave del teclado. Funciona con bases guardadas en iCloud Drive u otras ubicaciones de Archivos.")
            }
            .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)

            Section {
                Picker("Borrar lo copiado", selection: $model.clipboardSeconds) {
                    Text("A los 30 s").tag(30)
                    Text("Al minuto").tag(60)
                    Text("A los 2 minutos").tag(120)
                }
            } header: {
                Text("Portapapeles")
            } footer: {
                Text("Lo que copias solo se queda en este iPhone: no pasa al Mac por el portapapeles universal.")
            }
            .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)

            if model.vault?.recycleBinUUID != nil {
                Section {
                    Button("Vaciar la papelera", role: .destructive) { confirmEmptyBin = true }
                }
                .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)
            }

            Section {
                Toggle("Logos de las webs", isOn: $model.showFavicons).tint(Theme.green)
            } footer: {
                Text("Se descargan directamente de cada web, sin pasar por otros servicios.")
            }
            .listRowBackground(Theme.backgroundSubtle)
            .listRowSeparator(.hidden)

            Section {
                Button("Bloquear ahora", systemImage: "lock") { model.lock(manual: true) }
            }
            .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)

            Section {
                LabeledContent("Versión", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Link(destination: URL(string: "https://github.com/daviidltp/hush")!) {
                    Label("Código abierto en GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            } footer: {
                Text("Hush abre archivos KDBX, el formato abierto que usan muchas apps de contraseñas en el Mac, Windows y el móvil.")
            }
            .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)
        }
        .scrollContentBackground(.hidden)
        .background(HushBackground())
        .navigationTitle("Ajustes")
        .task { await refreshAutoFill() }
        .confirmationDialog("¿Vaciar la papelera?", isPresented: $confirmEmptyBin, titleVisibility: .visible) {
            Button("Vaciar", role: .destructive) { model.mutate { $0.emptyRecycleBin() } }
        } message: {
            Text("Lo que hay dentro se borra para siempre.")
        }
    }

    private func refreshAutoFill() async {
        autoFillOn = await ASCredentialIdentityStore.shared.state().isEnabled
    }
}
