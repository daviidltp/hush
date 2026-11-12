import SwiftUI
import UniformTypeIdentifiers

/// Pantalla de desbloqueo de una base: Face ID, contraseña maestra y archivo de clave.
struct UnlockView: View {
    @Environment(AppModel.self) private var model
    let db: SavedDatabase

    @State private var password = ""
    @State private var reveal = false
    @State private var showDatabases = false
    @State private var pickingKeyFile = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var faceID: Bool { model.canUseFaceID(db) }
    private var canSubmit: Bool { !model.busy && (!password.isEmpty || db.keyFileBookmark != nil) }

    var body: some View {
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
                    Button { Task { await model.unlockWithFaceID(db) } } label: {
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
                    if let progress = model.unlockProgress {
                        TimelineView(.animation) { context in
                            MeterBar(fraction: progress.done ? 1 : min(0.99, context.date.timeIntervalSince(progress.start) / max(progress.expected, 0.3)))
                        }
                        .padding(.horizontal, 6)
                        .transition(.opacity)
                    }
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
        .task {
            // Al volver a la app se pide Face ID solo; tras bloquear a mano, solo al tocar.
            if faceID, model.autoFaceID {
                await model.unlockWithFaceID(db)
            } else if !faceID {
                focused = true
            }
        }
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
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var creating = false

    var body: some View {
        ZStack {
            HushBackground()
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                AppMark(size: 64).padding(.bottom, 24)
                Text("Hush")
                    .font(.largeTitle.weight(.bold))
                    .tracking(-0.8)
                Text("Tus contraseñas en un archivo KDBX que controlas tú. El mismo que abres en el Mac.")
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)
                Spacer()
                VStack(spacing: 12) {
                    Button("Abrir archivo") { importing = true }
                        .buttonStyle(PrimaryButtonStyle())
                    Button { creating = true } label: {
                        Text("Crear base nueva")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    Text("Puede estar en iCloud Drive, Dropbox o cualquier sitio de la app Archivos.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.kdbx, .data]) { result in
            if case let .success(url) = result { model.add(url) }
        }
        .sheet(isPresented: $creating) { CreateDatabaseSheet() }
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
            }
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
            }
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
