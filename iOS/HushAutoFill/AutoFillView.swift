import BovedaCore
import KDBXKit
import LocalAuthentication
import Observation
import SwiftUI
import os

@MainActor
@Observable
final class AutoFillModel {
    enum Mode { case password, oneTimeCode }
    enum Result { case password(String, String), code(String), cancel }

    var mode: Mode = .password
    /// Webs o dominios que pide el sistema («github.com», «https://github.com/login»…).
    private(set) var services: [String] = []
    let databases = Preferences.databases
    var selectedID: UUID? = Preferences.lastDatabase
    private(set) var vault: Vault?
    /// La base que se abrió (para volver a pedir acceso al archivo al guardar).
    @ObservationIgnored private var openedDB: SavedDatabase?
    /// Guardando una entrada nueva, y por qué no se pudo.
    var saving = false
    var saveError: String?
    /// La tarjeta de «Guardar contraseña» está abierta encima de la lista.
    var composing = false
    var busy = false
    var error: String?
    /// El panel ya está en pantalla: antes de eso iOS cancela Face ID sin avisar.
    var appeared = false
    /// Face ID falló o se canceló: se enseñan los botones para reintentar o escribir la contraseña.
    var faceIDFailed = false
    /// Ha pulsado «Usar contraseña» (en el aviso de Face ID o en la pantalla).
    var wantsPassword = false
    /// Mientras se descifra: lo mismo que en la app (anillo con porcentaje).
    var progress: (start: Date, expected: Double, done: Bool)?
    @ObservationIgnored private var faceIDInProgress = false
    @ObservationIgnored var finish: (Result) -> Void = { _ in }

    var selected: SavedDatabase? { databases.first { $0.id == selectedID } ?? databases.first }

    func start(mode: Mode, services: [String]) {
        self.mode = mode
        self.services = services
    }

    var serviceName: String? {
        services.lazy.compactMap { BrowserMatch.host(of: $0) }.first
    }

    func canUseFaceID(_ db: SavedDatabase) -> Bool {
        Preferences.faceIDEnabled && BiometricKeychain.has(db.quickUnlockKey)
    }

    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID" : "Face ID"
    }

    var biometrySymbol: String { biometryName == "Touch ID" ? "touchid" : "faceid" }

    func unlockWithFaceID() async {
        guard let db = selected, canUseFaceID(db), !busy, !faceIDInProgress else { return }
        faceIDInProgress = true
        defer { faceIDInProgress = false }
        error = nil
        faceIDFailed = false
        do {
            let unlock = try await BiometricKeychain.load(db.quickUnlockKey, reason: "Rellenar con \(db.name)")
            try await open(db, unlock: unlock)
        } catch BiometricKeychain.Failure.wantsPassword {
            withAnimation(Theme.spring) { wantsPassword = true }
        } catch BiometricKeychain.Failure.cancelled {
            withAnimation(Theme.spring) { faceIDFailed = true }
        } catch BiometricKeychain.Failure.notFound {
            self.error = "La contraseña maestra ha cambiado. Escríbela en Hush para volver a activar \(biometryName)."
            withAnimation(Theme.spring) { wantsPassword = true }
        } catch {
            self.error = error.localizedDescription
            withAnimation(Theme.spring) { faceIDFailed = true }
        }
    }

    func unlock(password: String) async {
        guard let db = selected else { return }
        error = nil
        do {
            var keyData: Data?
            if let bookmark = db.keyFileBookmark {
                let url = try Bookmarks.resolve(bookmark).url
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                keyData = try Data(contentsOf: url)
            }
            let unlock: UnlockData
            if let keyData {
                unlock = password.isEmpty ? try UnlockData(keyFile: keyData) : try UnlockData(masterPassword: password, keyFile: keyData)
            } else {
                unlock = UnlockData(masterPassword: password)
            }
            try await open(db, unlock: unlock)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(_ db: SavedDatabase, unlock: UnlockData) async throws {
        busy = true
        defer { busy = false }
        let url = try Bookmarks.resolve(db.bookmark).url
        let start = Date()
        withAnimation(Theme.spring) { progress = (start, db.unlockSeconds ?? 1, false) }
        do {
            let opened = try await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try Vault.open(url: url, unlock: unlock)
            }.value
            Self.remember(seconds: Date().timeIntervalSince(start), for: db.id)
            progress?.done = true
            // Lo justo para ver el 100 %.
            try? await Task.sleep(for: .milliseconds(150))
            openedDB = db
            MemoryReport.log("tras abrir")
            withAnimation(Theme.spring) {
                vault = opened
                progress = nil
            }
        } catch {
            withAnimation(Theme.spring) { progress = nil }
            throw error
        }
    }

    /// Guarda lo que tardó, para que la próxima vez el anillo vaya al ritmo real (igual que en la app).
    private static func remember(seconds: Double, for id: UUID) {
        var all = Preferences.databases
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].unlockSeconds = seconds
        Preferences.databases = all
    }

    // MARK: Entradas

    private var all: [KDBX.Entry] {
        guard let vault else { return [] }
        return vault.root.allEntries(excluding: vault.excludedFromBrowsing)
            .filter { mode == .password ? !$0.string(FieldKey.password).isEmpty : TOTP.from($0) != nil }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Entradas de la web que pide el sistema.
    var suggestions: [KDBX.Entry] {
        guard let vault else { return [] }
        let pages = services.map { $0.contains("://") ? $0 : "https://" + $0 }
        return all.filter { entry in pages.contains { BrowserMatch.matches(page: $0, entry: entry, resolve: { vault.resolve($0) }) } }
    }

    func others(_ query: String) -> [KDBX.Entry] {
        let ids = Set(suggestions.map(\.uuid))
        let q = query.trimmingCharacters(in: .whitespaces)
        return all.filter { !ids.contains($0.uuid) }.filter { entry in
            q.isEmpty || [entry.title, entry.userName, entry.url].contains { $0.localizedStandardContains(q) }
        }
    }

    // MARK: Guardar una contraseña nueva

    /// Dominio que pide el sistema, para el título («github.com»).
    var suggestedTitle: String { serviceName.map(BrowserMatch.site(of:)) ?? "" }

    /// Web que pide el sistema, sin la ruta («https://github.com»).
    var suggestedURL: String { serviceName.map { "https://" + $0 } ?? "" }

    /// Carpetas donde se puede guardar (sin la papelera), con su nivel para sangrarlas.
    var folders: [(group: KDBX.Group, level: Int)] {
        guard let vault else { return [] }
        return vault.root.flattened(excluding: vault.excludedFromBrowsing)
    }

    var rootFolderID: UUID? { vault?.root.uuid }

    /// Añade la entrada y guarda con las mismas reglas que la app: verifica que el archivo nuevo se abre,
    /// copia previa y no pisa el archivo si cambió fuera. Si todo va bien, devuelve la credencial al campo.
    func saveNew(title: String, userName: String, password: String, url: String, folder: UUID?) async {
        guard var updated = vault, let db = openedDB, !saving else { return }
        saving = true
        defer { saving = false }
        saveError = nil
        var draft = EntryDraft(entry: .make(title: ""), groupID: folder ?? updated.root.uuid, isNew: true)
        draft.title = title.trimmingCharacters(in: .whitespaces)
        draft.userName = userName
        draft.password = password
        draft.url = url
        let entry = draft.apply(to: draft.original)
        let target = updated.root.group(draft.groupID) == nil ? updated.root.uuid : draft.groupID
        updated.addEntry(entry, to: target)
        let backups = AppGroup.backups
        do {
            let fileURL = try Bookmarks.resolve(db.bookmark).url
            let saved = try await Task.detached(priority: .userInitiated) { () throws -> Vault in
                let scoped = fileURL.startAccessingSecurityScopedResource()
                defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
                var copy = updated
                try copy.save(backups: backups)
                return copy
            }.value
            vault = saved
            Preferences.noteAutoFillSave(for: db.id)
            MemoryReport.log("tras guardar")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            finish(.password(userName, password))
        } catch VaultError.changedOnDisk {
            self.saveError = "El archivo ha cambiado desde otro dispositivo. Para no pisar esos cambios no se ha guardado. Cierra este panel, vuelve a abrirlo y guárdala de nuevo."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        } catch {
            self.saveError = "No se ha guardado: \(error.localizedDescription)"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    func choose(_ entry: KDBX.Entry) {
        guard let vault else { return }
        switch mode {
        case .password:
            finish(.password(vault.resolve(entry.userName), vault.resolve(entry.string(FieldKey.password))))
        case .oneTimeCode:
            if let totp = TOTP.from(entry) { finish(.code(totp.code())) }
        }
    }
}

// MARK: - Vistas

struct AutoFillView: View {
    @Environment(AutoFillModel.self) private var model

    var body: some View {
        NavigationStack {
            ZStack {
                if model.vault != nil {
                    AutoFillList()
                        .transition(.opacity)
                } else if let db = model.selected {
                    AutoFillUnlock(db: db)
                        .transition(.opacity)
                } else {
                    ContentUnavailableView("Sin bases", systemImage: "key.horizontal",
                                           description: Text("Abre Hush y elige tu archivo de contraseñas primero."))
                }
                if model.vault == nil, let progress = model.progress {
                    UnlockingView(name: model.selected?.name ?? "la base", progress: progress)
                        .transition(.opacity)
                }
            }
            .background(HushBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", systemImage: "xmark") { model.finish(.cancel) }
                }
            }
        }
        .overlay {
            if model.vault != nil, model.composing {
                SavePasswordOverlay()
            }
        }
        .animation(Theme.spring, value: model.composing)
        .tint(Theme.text)
    }
}

/// Igual que al abrir la app: con Face ID activado se pide solo, sin pantalla de por medio;
/// la contraseña solo aparece si se pide o si Face ID no está disponible.
struct AutoFillUnlock: View {
    @Environment(AutoFillModel.self) private var model
    let db: SavedDatabase

    var body: some View {
        Group {
            if model.canUseFaceID(db) && !model.wantsPassword {
                AutoFillFaceID(db: db)
            } else {
                AutoFillPassword(db: db)
            }
        }
        .animation(Theme.spring, value: model.wantsPassword)
    }
}

/// Fondo limpio mientras sale el aviso de Face ID; si se cancela o falla, botones para reintentar.
private struct AutoFillFaceID: View {
    @Environment(AutoFillModel.self) private var model
    let db: SavedDatabase

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if model.faceIDFailed {
                VStack(spacing: 0) {
                    Image(systemName: model.biometrySymbol)
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(Theme.text)
                        .frame(width: 84, height: 84)
                        .glassEffect(.regular, in: .circle)
                        .padding(.bottom, 24)
                        .accessibilityHidden(true)
                    Text("Hush está bloqueado")
                        .font(.title2.weight(.bold))
                        .tracking(-0.3)
                    Text(model.error ?? subtitle)
                        .font(.subheadline)
                        .foregroundStyle(model.error == nil ? Theme.textSecondary : Theme.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                        .padding(.horizontal, 32)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            Spacer()
            if model.faceIDFailed {
                VStack(spacing: 12) {
                    Button("Desbloquear con \(model.biometryName)") { Task { await model.unlockWithFaceID() } }
                        .buttonStyle(PrimaryButtonStyle())
                    Button { model.wantsPassword = true } label: {
                        Text("Usar contraseña")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .animation(Theme.spring, value: model.faceIDFailed)
        // Se pide en cuanto el panel está en pantalla (antes, iOS lo cancelaba sin avisar).
        .task(id: model.appeared) {
            guard model.appeared, !model.faceIDFailed else { return }
            await model.unlockWithFaceID()
        }
    }

    private var subtitle: String {
        if let service = model.serviceName {
            return "Usa \(model.biometryName) para rellenar \(service)."
        }
        return "Usa \(model.biometryName) para abrir \(db.name)."
    }
}

/// Contraseña maestra, con el mismo aspecto que la pantalla de desbloqueo de la app.
private struct AutoFillPassword: View {
    @Environment(AutoFillModel.self) private var model
    let db: SavedDatabase
    @State private var password = ""
    @State private var reveal = false
    @FocusState private var focused: Bool

    private var canSubmit: Bool { !model.busy && (!password.isEmpty || db.keyFileBookmark != nil) }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Spacer(minLength: focused ? 8 : 16)
            VStack(spacing: 6) {
                AppMark(size: focused ? 52 : 72).padding(.bottom, focused ? 8 : 12)
                if model.databases.count > 1 {
                    Picker("Base", selection: $model.selectedID) {
                        ForEach(model.databases) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.menu)
                    .font(.title3.weight(.bold))
                } else {
                    Text(db.name).font(.title.weight(.bold)).tracking(-0.4)
                }
                if let service = model.serviceName {
                    Text(model.mode == .password ? "Contraseña para \(service)" : "Código para \(service)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            // Con el teclado fuera no cabe todo: el botón de Face ID se esconde mientras escribes.
            if model.canUseFaceID(db) && !focused {
                Button {
                    model.wantsPassword = false
                    model.faceIDFailed = false
                    Task { await model.unlockWithFaceID() }
                } label: {
                    Image(systemName: model.biometrySymbol)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(Theme.text)
                        .frame(width: 72, height: 72)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(.top, 32)
                .accessibilityLabel("Desbloquear con \(model.biometryName)")
                .disabled(model.busy)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            Spacer(minLength: focused ? 8 : 16)
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Group {
                        if reveal {
                            TextField("Contraseña maestra", text: $password)
                        } else {
                            SecureField("Contraseña maestra", text: $password)
                        }
                    }
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit(submit)
                    Button { reveal.toggle() } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye")
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(reveal ? "Ocultar contraseña" : "Mostrar contraseña")
                }
                .padding(.leading, 20)
                .padding(.trailing, 8)
                .frame(height: 54)
                .glassEffect(.regular.interactive(), in: .capsule)
                if let error = model.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.red)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
                Button("Desbloquear") { submit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSubmit)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 12)
        }
        // Tocar fuera de los campos cierra el teclado (los botones siguen funcionando).
        .contentShape(Rectangle())
        .onTapGesture { focused = false }
        .animation(Theme.spring, value: focused)
        .animation(Theme.spring, value: model.error)
        .task(id: model.appeared) { if model.appeared { focused = true } }
    }

    private func submit() {
        guard canSubmit else { return }
        focused = false
        let typed = password
        Task { await model.unlock(password: typed) }
    }
}

struct AutoFillList: View {
    @Environment(AutoFillModel.self) private var model
    @State private var query = ""

    var body: some View {
        let suggestions = model.suggestions
        let others = model.others(query)
        List {
            if model.mode == .password, query.isEmpty {
                Section {
                    if suggestions.isEmpty {
                        NewPasswordCard(service: model.serviceName) { model.composing = true }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    } else {
                        Button { model.composing = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.onPrimary)
                                    .frame(width: 36, height: 36)
                                    .background(Circle().fill(Theme.primary))
                                Text("Guardar nueva contraseña").font(.body.weight(.medium)).foregroundStyle(Theme.text)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .listRowBackground(Theme.backgroundSubtle)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            if !suggestions.isEmpty, query.isEmpty {
                Section(model.serviceName.map { "Para \($0)" } ?? "Sugerencias") {
                    ForEach(suggestions, id: \.uuid) { row($0) }
                }
            }
            Section(query.isEmpty ? "Todas" : "Resultados") {
                ForEach(others, id: \.uuid) { row($0) }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(model.mode == .password ? "Elige una contraseña" : "Elige un código")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar")
    }

    private func row(_ entry: KDBX.Entry) -> some View {
        Button { model.choose(entry) } label: {
            HStack(spacing: 12) {
                EntryAvatar(title: entry.title, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title.isEmpty ? "Sin título" : entry.title).font(.body.weight(.medium)).foregroundStyle(Theme.text)
                    Text(entry.userName.isEmpty ? (BrowserMatch.host(of: entry.url) ?? " ") : entry.userName)
                        .font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: model.mode == .password ? "key.horizontal" : "clock")
                    .font(.subheadline).foregroundStyle(Theme.textTertiary)
            }
        }
        .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)
    }
}

/// Sin contraseñas para esta web: lo primero que se ve es guardar una nueva.
private struct NewPasswordCard: View {
    let service: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Theme.text)
                .frame(width: 56, height: 56)
                .glassEffect(.regular, in: .circle)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(service.map { "Nada guardado para \($0)" } ?? "Nada guardado para esta web")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text("Guarda la contraseña aquí y Hush la rellenará ahora y la próxima vez.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button("Guardar nueva contraseña", action: action)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous).fill(Theme.backgroundSubtle))
        .padding(.vertical, 4)
    }
}

/// Fondo atenuado y tarjeta de «Guardar contraseña», que baja desde arriba (el teclado ocupa la parte de abajo).
private struct SavePasswordOverlay: View {
    @Environment(AutoFillModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(shown ? 0.32 : 0)
                .ignoresSafeArea()
                .onTapGesture { close() }
                .accessibilityHidden(true)
            if shown {
                SavePasswordCard(close: close)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(y: -24).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .top)),
                        removal: .offset(y: -12).combined(with: .opacity)))
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: shown)
        .onAppear {
            // Entra un instante después del fondo, con un muelle sin rebote: se nota pero no salta.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.9).delay(0.04)) { shown = true }
        }
    }

    private func close() {
        guard !model.saving else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 1)) { shown = false }
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            model.composing = false
            model.saveError = nil
        }
    }
}

/// Aviso compacto para guardar: cabecera con la web, usuario y contraseña en dos filas, carpeta en una píldora
/// y los dos botones. Título y web van ya puestos con la web que pide el sistema; se pueden tocar para cambiarlos.
private struct SavePasswordCard: View {
    @Environment(AutoFillModel.self) private var model
    let close: () -> Void
    @State private var title = ""
    @State private var userName = ""
    @State private var password = ""
    @State private var url = ""
    @State private var folder: UUID?
    @State private var reveal = false
    @State private var generated = 0
    @FocusState private var focus: Field?

    enum Field: Hashable { case title, url, user, password }

    private var canSave: Bool { !password.isEmpty && !model.saving }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(spacing: 0) {
                fieldRow(symbol: "person") {
                    TextField("Usuario o correo", text: $userName)
                        .focused($focus, equals: .user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                }
                Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 44)
                fieldRow(symbol: "key.horizontal") {
                    HStack(spacing: 2) {
                        Group {
                            if reveal {
                                TextField("Contraseña", text: $password)
                            } else {
                                SecureField("Contraseña", text: $password)
                            }
                        }
                        .focused($focus, equals: .password)
                        .font(.mono(.body))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(save)
                        iconButton(reveal ? "eye.slash" : "eye", label: reveal ? "Ocultar contraseña" : "Mostrar contraseña") { reveal.toggle() }
                        iconButton("dice", label: "Generar contraseña segura") { generate() }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.backgroundSubtle))

            HStack(spacing: 8) {
                if password.isEmpty {
                    Button { generate() } label: {
                        Label("Generar una segura", systemImage: "sparkles")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(Capsule().fill(Theme.fill))
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                } else {
                    let strength = PasswordStrength.of(password)
                    MeterBar(fraction: strength.fraction, tint: Theme.strengthColor(strength.fraction))
                        .frame(maxWidth: 64)
                    Text(strength.label).font(.caption).foregroundStyle(Theme.textSecondary).fixedSize()
                        .transition(.opacity)
                }
                Spacer(minLength: 8)
                if model.folders.count > 1 { folderMenu }
            }
            .frame(minHeight: 32)

            if let error = model.saveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.red)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 10) {
                Button("Ahora no", action: close)
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 120)
                    .disabled(model.saving)
                Button(action: save) {
                    if model.saving {
                        ProgressView().tint(Theme.onPrimary)
                    } else {
                        Text("Guardar y rellenar")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canSave)
            }
        }
        .padding(16)
        // Cristal con un velo del fondo de la app: se nota el material sin que la lista de detrás se lea a través.
        .glassEffect(.regular.tint(Theme.background.opacity(0.72)), in: RoundedRectangle(cornerRadius: Theme.radiusLarge + 6, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 10)
        .animation(Theme.spring, value: password.isEmpty)
        .animation(Theme.spring, value: model.saveError)
        .sensoryFeedback(.impact(weight: .light), trigger: generated)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            model.saveError = nil
            title = model.suggestedTitle
            url = model.suggestedURL
            folder = model.rootFolderID
            focus = .user
        }
    }

    /// Avatar con la inicial, título editable y la web debajo; a la derecha, cerrar.
    private var header: some View {
        HStack(spacing: 12) {
            EntryAvatar(title: title.isEmpty ? "?" : title, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("Guardar contraseña")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Título", text: $title)
                    .focused($focus, equals: .title)
                    .font(.headline)
                    .submitLabel(.next)
                    .onSubmit { focus = .user }
                TextField("Web", text: $url)
                    .focused($focus, equals: .url)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.fill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar")
            .disabled(model.saving)
        }
    }

    private var folderMenu: some View {
        Menu {
            Picker("Carpeta", selection: $folder) {
                ForEach(model.folders, id: \.group.uuid) { item in
                    Text(item.level == 0 ? "Sin carpeta" : String(repeating: "   ", count: item.level - 1) + item.group.displayName)
                        .tag(Optional(item.group.uuid))
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.footnote)
                Text(folderName).font(.footnote.weight(.medium)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(Theme.fill))
        }
        .accessibilityLabel("Carpeta: \(folderName)")
    }

    private var folderName: String {
        guard let folder, folder != model.rootFolderID,
              let item = model.folders.first(where: { $0.group.uuid == folder }) else { return "Sin carpeta" }
        return item.group.displayName
    }

    private func fieldRow<Content: View>(symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 20)
                .accessibilityHidden(true)
            content()
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 48)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textSecondary)
        .accessibilityLabel(label)
    }

    private func generate() {
        password = PasswordGenerator.generate(Preferences.generator)
        reveal = true
        generated += 1
    }

    private func save() {
        guard canSave else { return }
        focus = nil
        let values = (title, userName, password, url.trimmingCharacters(in: .whitespaces), folder)
        Task { await model.saveNew(title: values.0, userName: values.1, password: values.2, url: values.3, folder: values.4) }
    }
}

/// Memoria que usa la extensión (iOS la cierra si se pasa), en el registro para comprobarlo.
enum MemoryReport {
    private static let logger = Logger(subsystem: "com.david.hush.autofill", category: "memoria")

    static func log(_ moment: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return }
        let used = Double(info.phys_footprint) / 1_048_576
        let peak = Double(info.ledger_phys_footprint_peak) / 1_048_576
        logger.notice("Memoria \(moment, privacy: .public): \(used, format: .fixed(precision: 1), privacy: .public) MB (pico \(peak, format: .fixed(precision: 1), privacy: .public) MB)")
    }
}
