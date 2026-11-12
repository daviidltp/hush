import BovedaCore
import KDBXKit
import SwiftUI

/// Crear o editar una entrada. Usa el mismo borrador que el Mac (`EntryDraft`), así se guarda igual en los dos.
struct EntryEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EntryDraft
    @State private var revealPassword = false
    @State private var showGenerator = false
    @State private var confirmDiscard = false
    @FocusState private var focus: Field?

    enum Field: Hashable { case title, user, password, url, otp, notes }

    init(draft: EntryDraft) {
        _draft = State(initialValue: draft)
    }

    private var canSave: Bool { draft.otpIsValid && draft.customKeysAreValid }
    private var changed: Bool { draft.apply(to: draft.original) != draft.original || draft.isNew }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Tipo", selection: $draft.kind) {
                        ForEach(EntryKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    TextField("Título", text: $draft.title)
                        .focused($focus, equals: .title)
                        .font(.body.weight(.medium))
                    if draft.kind == .login {
                        TextField("Usuario o correo", text: $draft.userName)
                            .focused($focus, equals: .user)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                        passwordField
                        TextField("Web", text: $draft.url)
                            .focused($focus, equals: .url)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                }
                .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)

                if draft.kind == .card {
                    Section("Tarjeta") {
                        ForEach(CardField.all, id: \.self) { key in
                            TextField(key, text: Binding(get: { draft.card[key] ?? "" }, set: { draft.card[key] = $0 }))
                                .keyboardType(key == CardField.holder ? .default : .numberPad)
                                .font(CardField.secret.contains(key) ? .mono(.body) : .body)
                        }
                    }
                    .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)
                }

                if draft.kind == .login {
                    Section {
                        TextField("Enlace otpauth:// o clave secreta", text: $draft.otp, axis: .vertical)
                            .focused($focus, equals: .otp)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.mono(.footnote))
                    } header: {
                        Text("Código 2FA")
                    } footer: {
                        if !draft.otpIsValid {
                            Text("No es un código 2FA válido.").foregroundStyle(Theme.red)
                        } else if let totp = TOTP.parse(draft.otp), !draft.otp.isEmpty {
                            Text("Código actual: \(totp.code())").font(.mono(.footnote))
                        }
                    }
                    .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)
                }

                Section("Notas") {
                    TextField("Notas", text: $draft.notes, axis: .vertical)
                        .focused($focus, equals: .notes)
                        .lineLimit(3...12)
                }
                .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)

                Section {
                    ForEach($draft.customFields) { $field in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Nombre", text: $field.key)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Theme.textSecondary)
                            TextField("Valor", text: $field.value, axis: .vertical)
                                .font(field.protected ? .mono(.body) : .body)
                            Toggle("Ocultar valor", isOn: $field.protected).tint(Theme.green)
                                .font(.footnote)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { draft.customFields.remove(atOffsets: $0) }
                    Button("Añadir campo", systemImage: "plus") {
                        withAnimation(Theme.spring) {
                            draft.customFields.append(.init(key: "Campo \(draft.customFields.count + 1)", value: "", protected: false))
                        }
                    }
                } header: {
                    Text("Otros campos")
                } footer: {
                    if !draft.customKeysAreValid {
                        Text("Cada campo necesita un nombre distinto que no sea uno de los fijos.").foregroundStyle(Theme.red)
                    }
                }
                .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)

                Section {
                    Picker("Grupo", selection: $draft.groupID) {
                        ForEach(groups, id: \.group.uuid) { item in
                            Text(String(repeating: "   ", count: item.level) + item.group.displayName).tag(item.group.uuid)
                        }
                    }
                    Toggle("Caduca", isOn: $draft.expires.animation(Theme.spring)).tint(Theme.green)
                    if draft.expires {
                        DatePicker("Fecha", selection: $draft.expiryDate, displayedComponents: .date)
                    }
                    TextField("Etiquetas, separadas por comas", text: $draft.tags)
                        .textInputAutocapitalization(.never)
                }
                .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)
            }
            .scrollContentBackground(.hidden)
            .background(HushBackground())
            .navigationTitle(draft.isNew ? "Nueva entrada" : "Editar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", systemImage: "xmark") {
                        if changed && !draft.isNew || !draft.title.isEmpty && draft.isNew { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar", systemImage: "checkmark") { save() }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("¿Descartar los cambios?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Descartar", role: .destructive) { dismiss() }
            }
            .sheet(isPresented: $showGenerator) {
                GeneratorSheet { draft.password = $0; revealPassword = true }
            }
            .onAppear { if draft.isNew { focus = .title } }
        }
        .interactiveDismissDisabled(changed && !draft.isNew)
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Group {
                    if revealPassword {
                        TextField("Contraseña", text: $draft.password)
                    } else {
                        SecureField("Contraseña", text: $draft.password)
                    }
                }
                .focused($focus, equals: .password)
                .font(.mono(.body))
                .textContentType(.newPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button { revealPassword.toggle() } label: {
                    Image(systemName: revealPassword ? "eye.slash" : "eye").frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel(revealPassword ? "Ocultar contraseña" : "Mostrar contraseña")
                Button { showGenerator = true } label: {
                    Image(systemName: "dice").frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text)
                .accessibilityLabel("Generar contraseña")
            }
            if !draft.password.isEmpty {
                let strength = PasswordStrengthInfo(draft.password)
                HStack(spacing: 8) {
                    MeterBar(fraction: strength.fraction, tint: Theme.strengthColor(strength.fraction))
                    Text(strength.label).font(.caption).foregroundStyle(Theme.textSecondary).fixedSize()
                }
            }
        }
    }

    private var groups: [(group: KDBX.Group, level: Int)] {
        guard let vault = model.vault else { return [] }
        return vault.root.flattened(excluding: vault.recycleBinUUID.map { [$0] } ?? [])
    }

    private func save() {
        let final = draft
        model.mutate { vault in
            if final.isNew {
                vault.addEntry(final.apply(to: final.original), to: final.groupID)
            } else {
                vault.updateEntry(final.original.uuid) { $0 = final.apply(to: $0) }
                if vault.locate(final.original.uuid)?.group.uuid != final.groupID {
                    vault.moveEntry(final.original.uuid, to: final.groupID)
                }
            }
        }
        model.toast = Toast(symbol: "checkmark", message: final.isNew ? "Entrada creada" : "Guardada")
        dismiss()
    }
}
