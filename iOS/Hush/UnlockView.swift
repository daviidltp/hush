import SwiftUI
import UniformTypeIdentifiers

/// Pantalla de desbloqueo de una base: Face ID, contraseña maestra y archivo de clave.
struct UnlockView: View {
    @Environment(AppModel.self) private var model
    let db: SavedDatabase

    @State private var password = UnlockView.testPassword
    @State private var reveal = false
    @State private var showDatabases = false
    @State private var pickingKeyFile = false
    /// Con Face ID activado se enseña primero Face ID; la contraseña solo si se pide.
    @State private var usePassword = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var faceID: Bool { model.canUseFaceID(db) }

    /// Solo en la versión de pruebas: `-HushTestPassword demo1234` al abrir rellena la contraseña de la base demo.
    static var testPassword: String {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "HushTestPassword") ?? ""
        #else
        return ""
        #endif
    }
    private var canSubmit: Bool { !model.busy && (!password.isEmpty || db.keyFileBookmark != nil) }

    var body: some View {
        if faceID && !usePassword && !model.faceIDWantsPassword {
            FaceIDLockView(db: db) {
                withAnimation(Theme.spring) { usePassword = true }
            }
        } else {
            passwordScreen
        }
    }

    private var passwordScreen: some View {
        ZStack {
            HushBackground()
            VStack(spacing: 0) {
                HStack {
                    Button { showDatabases = true } label: {
                        Label("Bases", systemImage: "square.stack.3d.up")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    Spacer()
                }
                .padding(.horizontal, Theme.gutter)

                Spacer(minLength: 24)

                VStack(spacing: 6) {
                    AppMark(size: 72).padding(.bottom, 12)
                    Text(db.name)
                        .font(.title.weight(.bold))
                        .tracking(-0.4)
                        .multilineTextAlignment(.center)
                    Text(db.location)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }

                if faceID {
                    Button {
                        withAnimation(Theme.spring) { usePassword = false }
                        Task { await model.unlockWithFaceID(db) }
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
                }

                Spacer(minLength: 24)

                VStack(spacing: 14) {
                    passwordField
                    if let error = model.unlockError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Theme.red)
                            .multilineTextAlignment(.center)
                            .transition(.opacity)
                    }
                    Button("Desbloquear") { submit() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!canSubmit)
                    keyFileRow
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 12)
            }
            .padding(.top, 8)
        }
        .animation(reduceMotion ? nil : Theme.spring, value: model.unlockError)
        .animation(reduceMotion ? nil : Theme.spring, value: model.unlockProgress == nil)
        .sheet(isPresented: $showDatabases) { DatabasesSheet() }
        .fileImporter(isPresented: $pickingKeyFile, allowedContentTypes: [.data]) { result in
            if case let .success(url) = result { model.setKeyFile(url, for: db) }
        }
        .task { focused = true }
    }

    private var passwordField: some View {
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
    }

    @ViewBuilder private var keyFileRow: some View {
        if let name = db.keyFileName {
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.key")
                Text(name).lineLimit(1)
                Button { model.setKeyFile(nil, for: db) } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel("Quitar archivo de clave")
            }
            .font(.footnote)
            .foregroundStyle(Theme.textSecondary)
        } else {
            Button("Usar archivo de clave") { pickingKeyFile = true }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focused = false
        let typed = password
        Task {
            await model.unlock(db, password: typed)
            if model.vault != nil { password = "" }
        }
    }
}

/// Primera vez: abrir un archivo KDBX o crear uno nuevo.
/// Basada en la bienvenida de Luma (Mobbin): icono arriba, título, tres ventajas y el botón abajo.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var creating = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    AppMark(size: 72)
                        .padding(.top, 56)
                        .padding(.bottom, 22)
                    Text("Tus contraseñas,\nen tu archivo")
                        .font(.largeTitle.weight(.bold))
                        .tracking(-0.8)
                        .multilineTextAlignment(.center)
                    Text("Hush abre el mismo archivo KDBX que usas en el Mac. Nada pasa por servidores de nadie.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                        .padding(.horizontal, 12)
                    VStack(alignment: .leading, spacing: 22) {
                        feature("folder", "Desde donde lo tengas", "iCloud Drive, Dropbox o cualquier carpeta de Archivos.")
                        feature(model.biometrySymbol, "Entra con \(model.biometryName)", "Escribe la contraseña maestra una vez y después solo te mira.")
                        feature("key.viewfinder", "Rellena al iniciar sesión", "Contraseñas y códigos 2FA desde la llave del teclado.")
                    }
                    .padding(.top, 40)
                }
                .padding(.horizontal, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 6) {
                Button("Abrir archivo") { importing = true }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Crear base nueva") { creating = true }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .frame(height: 44)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 4)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.kdbx, .data]) { result in
            if case let .success(url) = result { model.add(url) }
        }
        .sheet(isPresented: $creating) { CreateDatabaseSheet() }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.backgroundSubtle))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Lista de bases recordadas: cambiar de una a otra, añadir o quitar de la lista.
struct DatabasesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.databases) { db in
                        Button {
                            model.select(db.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "lock.fill")
                                    .font(.subheadline)
                                    .frame(width: 36, height: 36)
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(db.name).font(.body.weight(.medium))
                                    Text(db.location).font(.footnote).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                if db.id == model.selected?.id { Image(systemName: "checkmark").font(.body.weight(.semibold)) }
                            }
                            .foregroundStyle(Theme.text)
                        }
                        .listRowBackground(Theme.backgroundSubtle)
                        .listRowSeparator(.hidden)
                        .swipeActions {
                            Button("Quitar", role: .destructive) { model.remove(db) }
                        }
                    }
                } footer: {
                    Text("Quitar una base de la lista no borra el archivo.")
                }
                Section {
                    Button { importing = true } label: { Label("Abrir otro archivo", systemImage: "folder") }
                    Button { creating = true } label: { Label("Crear base nueva", systemImage: "plus") }
                }
                .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Bases")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo", systemImage: "checkmark") { dismiss() }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.kdbx, .data]) { result in
                if case let .success(url) = result {
                    model.add(url)
                    dismiss()
                }
            }
            .sheet(isPresented: $creating) { CreateDatabaseSheet() }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
    }
}

/// Crear una base nueva dentro de la carpeta de Hush.
struct CreateDatabaseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Contraseñas"
    @State private var password = ""
    @State private var repeated = ""

    private var strength: PasswordStrengthInfo { PasswordStrengthInfo(password) }
    private var valid: Bool { !password.isEmpty && password == repeated }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") { TextField("Nombre", text: $name) }
                    .listRowBackground(Theme.backgroundSubtle)
                    .listRowSeparator(.hidden)
                Section {
                    SecureField("Contraseña maestra", text: $password).textContentType(.newPassword)
                    SecureField("Repítela", text: $repeated).textContentType(.newPassword)
                    if !password.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            MeterBar(fraction: strength.fraction, tint: Theme.strengthColor(strength.fraction))
                            Text(strength.label).font(.footnote).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Contraseña maestra")
                } footer: {
                    Text("Si la olvidas no hay forma de recuperar la base. Se guarda en Archivos → En mi iPhone → Hush; puedes moverla a iCloud Drive.")
                }
                .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Base nueva")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crear", systemImage: "checkmark") {
                        let n = name, p = password
                        Task {
                            await model.create(name: n, password: p)
                            dismiss()
                        }
                    }
                    .disabled(!valid || model.busy)
                }
            }
        }
    }
}

/// Bloqueo con Face ID: al abrir la app solo se ve el aviso del sistema, sin nada detrás.
/// Si se cancela o falla, aparece lo justo para reintentar o usar la contraseña.
struct FaceIDLockView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let db: SavedDatabase
    let usePassword: () -> Void

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if model.faceIDFailed {
                VStack(spacing: 0) {
                    Spacer()
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
                    Text(model.unlockError ?? "Usa \(model.biometryName) para abrir \(db.name).")
                        .font(.subheadline)
                        .foregroundStyle(model.unlockError == nil ? Theme.textSecondary : Theme.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                        .padding(.horizontal, 32)
                    Spacer()
                    VStack(spacing: 12) {
                        Button("Desbloquear con \(model.biometryName)") { retry() }
                            .buttonStyle(PrimaryButtonStyle())
                        Button(action: usePassword) {
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
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if model.busy {
                ProgressView().transition(.opacity)
            }
        }
        .animation(Theme.spring, value: model.faceIDFailed)
        .animation(Theme.spring, value: model.busy)
        // Se pide al aparecer y cada vez que la app vuelve de segundo plano (no tras bloquear a mano).
        // El propio aviso de Face ID pone la app «inactiva» un momento: eso no cuenta como volver.
        .task {
            guard !model.faceIDFailed else { return }
            await model.unlockWithFaceID(db)
        }
        .onChange(of: scenePhase) { old, new in
            guard old == .background, new != .background else { return }
            model.faceIDFailed = false
            Task { await model.unlockWithFaceID(db) }
        }
    }

    private func retry() {
        model.faceIDFailed = false
        Task { await model.unlockWithFaceID(db) }
    }
}

// MARK: - Abriendo

/// Pantalla mientras se descifra la base: candado dentro de un anillo que avanza con lo que tardó la
/// última vez, y debajo el paso en el que va. Al terminar, el candado se abre.
struct UnlockingView: View {
    let name: String
    let progress: (start: Date, expected: Double, done: Bool)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let steps = ["Comprobando la clave", "Descifrando \u{00AB}%@\u{00BB}", "Abriendo tus contraseñas"]

    var body: some View {
        TimelineView(.animation) { context in
            let fraction = progress.done ? 1 : min(0.95, context.date.timeIntervalSince(progress.start) / max(progress.expected, 0.4))
            let step = progress.done ? 3 : (fraction < 0.25 ? 0 : fraction < 0.75 ? 1 : 2)
            VStack(spacing: 28) {
                ZStack {
                    Circle().stroke(Theme.track, lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(Theme.text, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: progress.done ? "lock.open.fill" : "lock.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .contentTransition(.symbolEffect(.replace))
                }
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
