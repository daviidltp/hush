import AuthenticationServices
import BovedaCore
import SwiftUI

/// Ajustes: base abierta, seguridad, autorrelleno y poco más.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var confirmEmptyBin = false
    @State private var autoFillOn = false
    @State private var renaming: RenameTarget?
    @State private var newName = ""

    enum RenameTarget: Identifiable {
        case database, file
        var id: Self { self }
    }

    var body: some View {
        @Bindable var model = model
        Form {
            if let db = model.openDatabase {
                Section(header: ListHeader("Base abierta")) {
                    editableRow("Nombre", value: model.vault?.name ?? db.name) {
                        newName = model.vault?.name ?? db.name
                        renaming = .database
                    }
                    editableRow("Archivo", value: db.name + ".kdbx") {
                        newName = db.name
                        renaming = .file
                    }
                    LabeledContent("Ubicación", value: db.location)
                    if model.saving {
                        LabeledContent("Estado", value: "Guardando…")
                    } else if model.unsaved {
                        LabeledContent("Estado") { Text("Sin guardar").foregroundStyle(Theme.red) }
                    }
                }
                .rowStyle()
            }

            Section(header: ListHeader("Seguridad")) {
                Toggle("Desbloquear con \(model.biometryName)", isOn: $model.faceIDEnabled).tint(Theme.green)
                ChoiceRow(title: "Bloquear al salir", selection: $model.autoLockSeconds, options: [
                    (0, "Al momento"), (60, "Tras 1 minuto"), (300, "Tras 5 minutos"), (900, "Tras 15 minutos"),
                ])
                ChoiceRow(title: "Borrar lo copiado", selection: $model.clipboardSeconds, options: [
                    (30, "A los 30 segundos"), (60, "Al minuto"), (120, "A los 2 minutos"),
                ])
            }
            .rowStyle()

            Section(header: ListHeader("Estilo")) {
                ChoiceRow(title: "Tema", selection: $model.appearance,
                          options: Appearance.allCases.map { ($0, $0.label) })
                ChoiceRow(title: "Contraseñas", selection: $model.browseStyle,
                          options: BrowseStyle.allCases.map { ($0, $0.label) })
            }
            .rowStyle()

            Section {
                Button(action: turnOnAutoFill) {
                    LabeledContent("Autorrelleno") {
                        Text(autoFillOn ? "Activado" : "Activar")
                            .foregroundStyle(autoFillOn ? Theme.green : Theme.blue)
                    }
                }
                .foregroundStyle(Theme.text)
                Toggle("Logos de las webs", isOn: $model.showFavicons).tint(Theme.green)
            }
            .rowStyle()

            Section {
                Button("Bloquear ahora", systemImage: "lock") { model.lock(manual: true) }
                    .foregroundStyle(Theme.text)
                if model.vault?.recycleBinUUID != nil {
                    Button(role: .destructive) { confirmEmptyBin = true } label: {
                        Label { Text("Vaciar la papelera") } icon: { Image(systemName: "trash") }
                            .foregroundStyle(Theme.red)
                    }
                }
            }
            .rowStyle()

            Section {
                Link(destination: URL(string: "https://github.com/daviidltp/hush")!) {
                    LabeledContent("Código abierto", value: "GitHub")
                }
                .foregroundStyle(Theme.text)
            } footer: {
                Text("Hush \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
            .rowStyle()
        }
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 12, for: .scrollContent)
        .background(HushBackground())
        .navigationTitle("Ajustes")
        .task { await refreshAutoFill() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAutoFill() }
        }
        .confirmationDialog("¿Vaciar la papelera?", isPresented: $confirmEmptyBin, titleVisibility: .visible) {
            Button("Vaciar", role: .destructive) { model.mutate { $0.emptyRecycleBin() } }
        } message: {
            Text("Lo que hay dentro se borra para siempre.")
        }
        .alert(renaming == .file ? "Nombre del archivo" : "Nombre de la base",
               isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { target in
            TextField("Nombre", text: $newName)
                .textInputAutocapitalization(.sentences)
            Button("Cancelar", role: .cancel) {}
            Button("Guardar") {
                switch target {
                case .database: model.renameDatabase(to: newName)
                case .file: Task { await model.renameFile(to: newName) }
                }
            }
        } message: { target in
            Text(target == .file ? "Cambia el nombre del archivo .kdbx." : "Es el nombre que se ve dentro de la base.")
        }
    }

    /// Fila con el valor a la derecha que se puede tocar para cambiarlo.
    private func editableRow(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LabeledContent(title) {
                HStack(spacing: 6) {
                    Text(value).lineLimit(1).foregroundStyle(Theme.textSecondary)
                    Image(systemName: "pencil").font(.footnote).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .foregroundStyle(Theme.text)
    }

    /// Pide a iOS activar Hush como app de contraseñas; si no puede, abre la pantalla de Ajustes donde se activa.
    private func turnOnAutoFill() {
        Task {
            if autoFillOn {
                try? await ASSettingsHelper.openCredentialProviderAppSettings()
                return
            }
            do {
                let on = try await ASSettingsHelper.requestToTurnOnCredentialProviderExtension()
                if !on { try await ASSettingsHelper.openCredentialProviderAppSettings() }
            } catch {
                log.error("Autorrelleno: \(error.localizedDescription, privacy: .public)")
                do { try await ASSettingsHelper.openCredentialProviderAppSettings() } catch {
                    openURL(URL(string: UIApplication.openSettingsURLString)!)
                }
            }
            await refreshAutoFill()
        }
    }

    private func refreshAutoFill() async {
        autoFillOn = await ASCredentialIdentityStore.shared.state().isEnabled
    }
}

/// Fila con la opción elegida a la derecha; al tocarla abre la lista de opciones con un check.
struct ChoiceRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        NavigationLink {
            ChoiceList(title: title, selection: $selection, options: options)
        } label: {
            LabeledContent(title, value: options.first { $0.0 == selection }?.1 ?? "")
        }
    }
}

private struct ChoiceList<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(options, id: \.0) { value, label in
                Button {
                    selection = value
                    dismiss()
                } label: {
                    HStack {
                        Text(label).foregroundStyle(Theme.text)
                        Spacer()
                        if value == selection {
                            Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Theme.text)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .rowStyle()
            }
        }
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 12, for: .scrollContent)
        .background(HushBackground())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

