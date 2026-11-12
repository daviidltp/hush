import BovedaCore
import KDBXKit
import SwiftUI

struct EntryEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: EntryDraft
    @State private var revealPassword = false
    @State private var showGenerator = false
    @FocusState private var focus: Field?

    enum Field: Hashable { case title, user, password, url, otp, notes, tags, card(String) }
    @State private var creatingAlias = false

    private var canSave: Bool { draft.otpIsValid && draft.customKeysAreValid }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if draft.isNew { kindPicker }

                    switch draft.kind {
                    case .login:
                        VStack(spacing: 0) {
                            EditRow(L("Usuario"), focused: focus == .user) { userField }
                            Divider().padding(.horizontal, 14)
                            EditRow(L("Contraseña"), focused: focus == .password) { passwordField }
                            Divider().padding(.horizontal, 14)
                            EditRow(L("Web"), focused: focus == .url) {
                                TextField("https://", text: $draft.url).focused($focus, equals: .url)
                            }
                            Divider().padding(.horizontal, 14)
                            EditRow(L("Código 2FA"), focused: focus == .otp) { otpField }
                        }
                        .card()
                    case .card:
                        CardArt(holder: draft.card[CardField.holder] ?? "", number: draft.card[CardField.number] ?? "",
                                expiry: draft.card[CardField.expiry] ?? "", title: draft.title)
                            .frame(maxWidth: .infinity)
                        VStack(spacing: 0) {
                            cardRow(L("Número de tarjeta"), CardField.number, placeholder: "0000 0000 0000 0000", mono: true)
                            Divider().padding(.horizontal, 14)
                            cardRow(L("Titular"), CardField.holder, placeholder: L("Como aparece en la tarjeta"))
                            Divider().padding(.horizontal, 14)
                            HStack(spacing: 0) {
                                cardRow(L("Caducidad"), CardField.expiry, placeholder: L("MM/AA"), mono: true)
                                Divider().frame(height: 34)
                                cardRow("CVV", CardField.cvv, placeholder: "123", mono: true, secure: true)
                                Divider().frame(height: 34)
                                cardRow("PIN", CardField.pin, placeholder: L("Opcional"), mono: true, secure: true)
                            }
                        }
                        .card()
                    case .note:
                        EmptyView()
                    }

                    VStack(spacing: 0) {
                        EditRow(L("Grupo"), focused: false) { groupMenu }
                        Divider().padding(.horizontal, 14)
                        EditRow(L("Etiquetas"), focused: focus == .tags) {
                            TextField("Separadas por comas", text: $draft.tags).focused($focus, equals: .tags)
                        }
                        Divider().padding(.horizontal, 14)
                        HStack {
                            Text("Caduca").font(.ui(13))
                            Spacer()
                            if draft.expires {
                                DatePicker("Fecha de caducidad", selection: $draft.expiryDate, displayedComponents: .date)
                                    .labelsHidden()
                                    .datePickerStyle(.field)
                                    .fixedSize()
                            }
                            Toggle("Caduca", isOn: $draft.expires.animation(.easeOut(duration: 0.15)))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                    }
                    .card()

                    EditorSection(draft.kind == .note ? L("Nota · admite Markdown (# título, - lista, **negrita**)") : L("Notas")) {
                        TextEditor(text: $draft.notes)
                            .font(draft.kind == .note ? .mono(13) : .ui(13))
                            .scrollContentBackground(.hidden)
                            .scrollIndicators(.never)
                            .focused($focus, equals: .notes)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 10)
                            .frame(minHeight: draft.kind == .note ? 300 : 90)
                            .card()
                            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
                                .strokeBorder(focus == .notes ? Theme.borderStrong : .clear))
                    }

                    CustomFieldsEditor(fields: $draft.customFields)
                    if !draft.customKeysAreValid {
                        Text("Cada campo necesita un nombre distinto y que no sea uno de los estándar.")
                            .font(.ui(12)).foregroundStyle(Theme.red)
                    }
                }
                .padding(24)
            }
            .scrollIndicators(.automatic)

            HStack(spacing: 8) {
                if !draft.isNew {
                    Text("La versión anterior se guarda en el historial")
                        .font(.ui(11)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(GButtonStyle(kind: .ghost))
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Crear" : "Guardar") { model.commit(draft) }
                    .buttonStyle(GButtonStyle(kind: .primary))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .frame(height: 60)
            .hairline(.top)
        }
        .frame(width: 560, height: 660)
        .background(Theme.background)
        .onAppear { focus = draft.isNew ? .title : nil }
    }

    /// Icono (el logo de la web en cuanto se escribe) y título grande sin caja, como en el detalle.
    private var header: some View {
        HStack(spacing: 14) {
            DraftIcon(title: draft.title, url: draft.kind == .login ? draft.url : "", kind: draft.kind)
            VStack(alignment: .leading, spacing: 4) {
                TextField(draft.isNew ? ["Nueva entrada", "Nombre de la tarjeta", "Nueva nota"][EntryKind.allCases.firstIndex(of: draft.kind)!] : "Título", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.ui(20, .semibold))
                    .frame(minHeight: 28)
                    .focused($focus, equals: .title)
                Text(L("En ") + (model.root?.group(draft.groupID)?.displayName ?? ""))
                    .font(.ui(12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.bottom, 4)
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                Group {
                    if revealPassword { TextField("", text: $draft.password) } else { SecureField("", text: $draft.password) }
                }
                .accessibilityLabel("Contraseña")
                .font(.mono(13))
                .focused($focus, equals: .password)
                IconButton(symbol: revealPassword ? "eye.slash" : "eye", help: revealPassword ? L("Ocultar") : L("Mostrar"), size: 26) { revealPassword.toggle() }
                IconButton(symbol: "arrow.clockwise", help: L("Generar otra"), size: 26) {
                    draft.password = PasswordGenerator.generate(Preferences.generator)
                    revealPassword = true
                }
                IconButton(symbol: "slider.horizontal.3", help: L("Opciones del generador"), size: 26) { showGenerator.toggle() }
                    .popover(isPresented: $showGenerator, arrowEdge: .trailing) {
                        GeneratorView { generated in
                            draft.password = generated
                            revealPassword = true
                            showGenerator = false
                        }
                        .frame(width: 340)
                    }
            }
            if !draft.password.isEmpty {
                // Con una referencia ({REF:…}) se valora la contraseña a la que apunta, no el texto de la referencia.
                let effective = model.resolved(draft.password)
                let strength = PasswordStrength.of(effective)
                if Preferences.checkBreaches, (AuditServices.shared.pwnedCount(for: effective) ?? 0) > 0 {
                    StrengthBar(fraction: 0.08, label: L("Filtrada · cámbiala"))
                } else {
                    StrengthBar(fraction: strength.fraction, label: strength.label)
                }
            }
        }
    }

    private var kindPicker: some View {
        HStack(spacing: 6) {
            ForEach(EntryKind.allCases, id: \.self) { kind in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if kind == .login && draft.password.isEmpty { draft.password = PasswordGenerator.generate(Preferences.generator) }
                        if kind != .login && draft.kind == .login && !draft.isNew { return }
                        draft.kind = kind
                    }
                } label: {
                    Label(kind.label, systemImage: kind.symbol)
                        .font(.ui(12, .medium))
                        .foregroundStyle(draft.kind == kind ? Theme.onPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(draft.kind == kind ? Theme.primary : Theme.fill))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func cardRow(_ label: String, _ key: String, placeholder: String, mono: Bool = false, secure: Bool = false) -> some View {
        let binding = Binding(get: { draft.card[key] ?? "" }, set: { draft.card[key] = $0 })
        return EditRow(label, focused: focus == .card(key)) {
            Group {
                if secure && !revealPassword { SecureField(placeholder, text: binding) } else { TextField(placeholder, text: binding) }
            }
            .font(mono ? .mono(13) : .ui(13))
            .focused($focus, equals: .card(key))
        }
    }

    private var userField: some View {
        HStack(spacing: 2) {
            TextField("nombre@correo.com", text: $draft.userName).focused($focus, equals: .user)
            if SimpleLogin.isConfigured {
                if creatingAlias {
                    ProgressView().controlSize(.small).frame(width: 26, height: 26)
                } else {
                    IconButton(symbol: "at.badge.plus", help: L("Crear un alias de email con SimpleLogin"), size: 26) { createAlias() }
                }
            }
        }
    }

    private func createAlias() {
        creatingAlias = true
        let host = FaviconStore.host(of: draft.url)
        Task {
            do {
                draft.userName = try await SimpleLogin.createAlias(for: host, note: draft.title)
            } catch {
                model.alert = AppModel.AlertMessage(title: L("No se ha podido crear el alias"), message: error.localizedDescription)
            }
            creatingAlias = false
        }
    }

    private var otpField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Enlace otpauth:// o clave secreta", text: $draft.otp)
                .focused($focus, equals: .otp)
            if !draft.otpIsValid {
                Text("No es un código 2FA válido").font(.ui(11)).foregroundStyle(Theme.red)
            } else if let totp = TOTP.parse(draft.otp), !draft.otp.isEmpty {
                Text(L("Código actual: \(totp.code())")).font(.mono(11)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var groupMenu: some View {
        let groups = model.root?.flattened(excluding: model.vault?.excludedFromBrowsing ?? []) ?? []
        let current = groups.first { $0.group.uuid == draft.groupID }?.group.displayName ?? ""
        return Menu {
            ForEach(groups, id: \.group.uuid) { item in
                Button {
                    draft.groupID = item.group.uuid
                } label: {
                    Text(String(repeating: "    ", count: item.level) + item.group.displayName)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Text(current).font(.ui(13)).foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// Fila editable dentro de una tarjeta: etiqueta pequeña arriba y el campo sin caja debajo.
private struct EditRow<Content: View>: View {
    let label: String
    let focused: Bool
    @ViewBuilder var content: Content

    init(_ label: String, focused: Bool, @ViewBuilder content: () -> Content) {
        self.label = label
        self.focused = focused
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.ui(11, .medium)).foregroundStyle(focused ? Theme.textSecondary : Theme.textTertiary)
                .accessibilityHidden(true)
            content
                .textFieldStyle(.plain)
                .font(.ui(13))
        }
        // VoiceOver anuncia el nombre del campo («Web», «CVV»…) y no su texto de ejemplo.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .background(focused ? Theme.hover.opacity(0.6) : .clear)
    }
}

private struct EditorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.ui(12, .medium)).foregroundStyle(Theme.textSecondary)
            content
        }
    }
}

/// Icono del borrador: el logo de la web si ya se sabe, si no la inicial.
private struct DraftIcon: View {
    let title: String
    let url: String
    var kind: EntryKind = .login

    var body: some View {
        if let image = FaviconStore.shared.image(for: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.border))
        } else if title.trimmingCharacters(in: .whitespaces).isEmpty {
            Image(systemName: kind.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.fill))
        } else {
            EntryAvatar(title: title, size: 44)
        }
    }
}

private struct CustomFieldsEditor: View {
    @Binding var fields: [EntryDraft.CustomField]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Campos personalizados").font(.ui(12, .medium)).foregroundStyle(Theme.textSecondary)
            if !fields.isEmpty {
                VStack(spacing: 0) {
                    ForEach($fields) { $field in
                        if field.id != fields.first?.id { Divider().padding(.horizontal, 14) }
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("Nombre", text: $field.key)
                                    .font(.ui(11, .medium))
                                    .foregroundStyle(Theme.textSecondary)
                                Group {
                                    if field.protected { SecureField("Valor", text: $field.value) } else { TextField("Valor", text: $field.value) }
                                }
                                .font(.ui(13))
                            }
                            .textFieldStyle(.plain)
                            IconButton(symbol: field.protected ? "lock.fill" : "lock.open", help: field.protected ? L("Oculto: pulsa para mostrarlo") : L("Visible: pulsa para ocultarlo"), size: 26) { field.protected.toggle() }
                            IconButton(symbol: "minus.circle", help: L("Quitar campo"), size: 26) { fields.removeAll { $0.id == field.id } }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
                .card()
            }
            Button {
                fields.append(.init(key: "", value: "", protected: false))
            } label: {
                Label("Añadir campo", systemImage: "plus")
            }
            .buttonStyle(GButtonStyle(kind: .ghost, compact: true))
            .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Generador de contraseñas en un panel flotante y en la barra de menús.
struct GeneratorView: View {
    @Environment(AppModel.self) private var model
    let onUse: ((String) -> Void)?
    /// En la barra de menús la cabecera ya dice «Generador».
    var showsTitle = true
    @State private var options = Preferences.generator
    @State private var password = ""
    @State private var copied = false
    @State private var copiedTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsTitle {
                Text("Generador").font(.ui(14, .semibold))
            }

            // La contraseña con sus acciones dentro, como el resto de campos de Hush.
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 4) {
                    ColoredPassword(password: password)
                        .font(.mono(14))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)  // Siempre entera, aunque sean diez palabras.
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .padding(.top, 4)
                        .accessibilityLabel("Contraseña generada")
                    IconButton(symbol: "arrow.clockwise", help: L("Generar otra (⌘R)"), size: 28) { regenerate() }
                        .keyboardShortcut("r", modifiers: .command)
                    IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: copied ? L("Copiada") : L("Copiar"),
                               size: 28, tint: copied ? Theme.green : Theme.textSecondary) { copy() }
                }
                let bits = PasswordGenerator.entropy(options)
                StrengthBar(fraction: min(bits / 128, 1), label: "\(PasswordStrength.of(bits: bits).label) · \(Int(bits)) bits")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.backgroundSubtle))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))

            Picker("Tipo", selection: $options.usePassphrase) {
                Text("Caracteres").tag(false)
                Text("Palabras").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if options.usePassphrase {
                stepperRow(L("Palabras"), value: options.wordCount) {
                    Slider(value: Binding(get: { Double(options.wordCount) }, set: { options.wordCount = Int($0.rounded()) }), in: 3...10, step: 1)
                        .accessibilityLabel("Número de palabras")
                        .accessibilityValue("\(options.wordCount)")
                }
                HStack(spacing: 6) {
                    Text("Separador").font(.ui(12, .medium)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    ForEach(["-", ".", "_", " "], id: \.self) { sep in
                        chip(sep == " " ? "␣" : sep, help: sep == " " ? L("Espacio") : sep,
                             Binding(get: { options.separator == sep }, set: { if $0 { options.separator = sep } }))
                            .frame(width: 34)
                    }
                }
                HStack(spacing: 14) {
                    Toggle("Mayúscula inicial", isOn: $options.capitalize)
                    Toggle("Añadir un número", isOn: $options.addNumber)
                }
                .toggleStyle(.checkbox).font(.ui(12))
            } else {
                stepperRow(L("Longitud"), value: options.length) {
                    Slider(value: Binding(get: { Double(options.length) }, set: { options.length = Int($0.rounded()) }), in: 8...64)
                        .accessibilityLabel("Longitud")
                        .accessibilityValue("\(options.length) caracteres")
                }
                HStack(spacing: 6) {
                    chip("ABC", help: L("Mayúsculas"), $options.uppercase)
                    chip("abc", help: L("Minúsculas"), $options.lowercase)
                    chip("123", help: L("Números"), $options.digits)
                    chip("#$&", help: L("Símbolos"), $options.symbols)
                }
                Toggle("Evitar caracteres que se confunden (l, 1, O, 0)", isOn: $options.avoidAmbiguous)
                    .toggleStyle(.checkbox).font(.ui(12))
            }

            if let onUse {
                HStack {
                    Spacer()
                    Button("Usar esta") { onUse(password) }
                        .buttonStyle(GButtonStyle(kind: .primary, compact: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .background(Theme.background)
        .onAppear(perform: regenerate)
        .onDisappear { copiedTask?.cancel() }
        .onChange(of: options) { _, new in
            Preferences.generator = new
            regenerate()
        }
    }

    /// Etiqueta, control y valor en una sola fila.
    private func stepperRow<Control: View>(_ label: String, value: Int, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.ui(12, .medium)).foregroundStyle(Theme.textSecondary)
            control().controlSize(.small)
            Text("\(value)").font(.mono(12, .medium)).frame(minWidth: 22, alignment: .trailing)
        }
    }

    private func copy() {
        model.copy(password, label: L("Contraseña"), markUsed: false)
        copiedTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) { copied = true }
        copiedTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }

    private func regenerate() {
        password = PasswordGenerator.generate(options)
        copiedTask?.cancel()
        copied = false
    }

    /// Interruptor de un tipo de carácter: activo con fondo suave y marca; apagado, solo el borde.
    private func chip(_ label: String, help: String, _ isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                if isOn.wrappedValue {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                }
                Text(label).font(.mono(12, .medium))
            }
            .foregroundStyle(isOn.wrappedValue ? Theme.text : Theme.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(isOn.wrappedValue ? Theme.selected : Theme.background))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(isOn.wrappedValue ? Theme.borderStrong : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }
}
