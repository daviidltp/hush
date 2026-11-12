import AppKit
import BovedaCore
import SwiftUI
import UniformTypeIdentifiers

/// Marca de la app: un cuadrado negro con un candado, al estilo del triángulo de Vercel.
struct AppMark: View {
    var size: CGFloat = 40
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Theme.onPrimary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24).fill(Theme.primary))
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    AppMark()
                    Text("Hush")
                        .font(.ui(28, .semibold))
                        .tracking(-0.6)
                    Text("Tus contraseñas, en tu archivo KDBX. Sin nube, sin cuentas.")
                        .font(.ui(14))
                        .foregroundStyle(Theme.textSecondary)
                }

                if !model.recents.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recientes")
                            .font(.ui(12, .medium))
                            .foregroundStyle(Theme.textSecondary)
                        // Con muchas bases la lista se desplaza y los botones de abajo siguen a la vista.
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(model.recents.enumerated()), id: \.element) { index, url in
                                    RecentRow(url: url)
                                    if index < model.recents.count - 1 { Divider().overlay(Theme.border) }
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        // Filas de 56 pt: hasta 5 se ven enteras; a partir de ahí, se desplaza.
                        .frame(height: CGFloat(min(model.recents.count, 5)) * 57)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge))
                        .background(RoundedRectangle(cornerRadius: Theme.radiusLarge).fill(Theme.background))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge).strokeBorder(Theme.border))
                    }
                }

                HStack(spacing: 8) {
                    Button("Abrir base de datos…") { model.openPanel() }
                        .buttonStyle(GButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                    Button("Crear nueva") { model.wantsCreate = true }
                        .buttonStyle(GButtonStyle(kind: .secondary))
                }
            }
            .frame(width: 440)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.backgroundSubtle)
        .sheet(isPresented: Binding(get: { model.wantsCreate }, set: { model.wantsCreate = $0 })) { CreateVaultSheet() }
    }
}

private struct RecentRow: View {
    @Environment(AppModel.self) private var model
    let url: URL
    @State private var hovering = false

    var body: some View {
        Button { model.choose(url) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.ui(13, .medium))
                    Text(url.deletingLastPathComponent().path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.ui(11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if QuickUnlock.isEnrolled(url) {
                    Image(systemName: "touchid").foregroundStyle(Theme.textTertiary).help("Touch ID activado")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 56)
            .background(hovering ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Quitar de recientes", role: .destructive) { model.removeRecent(url) }
        }
    }
}

struct UnlockView: View {
    @Environment(AppModel.self) private var model
    let url: URL
    @State private var password = ""
    @State private var reveal = false
    @State private var keyFile: URL?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shake = false
    /// Con Touch ID se muestra primero la huella; la contraseña aparece si se cancela, falla o se pide.
    @State private var usePassword = false
    private var waitingForTouchID: Bool { touchID && !usePassword }

    private var touchID: Bool { model.canUseTouchID(for: url) }
    private var name: String { url.deletingPathExtension().lastPathComponent }
    private var canSubmit: Bool { !model.busy && !(password.isEmpty && keyFile == nil) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 26) {
                vaultTitle

                if waitingForTouchID {
                    touchIDPrompt
                } else {
                VStack(spacing: 12) {
                    passwordField
                        .offset(x: shake ? -8 : 0)

                    // Hueco fijo para el error o la barra: al aparecer no mueven el campo que estás corrigiendo.
                    ZStack {
                        Text(model.unlockError ?? " ")
                            .font(.ui(12))
                            .foregroundStyle(Theme.red)
                            .multilineTextAlignment(.center)
                            .lineLimit(2, reservesSpace: true)
                            .opacity(model.unlockError == nil || model.unlockProgress != nil ? 0 : 1)
                            .animation(.easeOut(duration: 0.15), value: model.unlockError)
                        if let progress = model.unlockProgress {
                            UnlockProgressBar(progress: progress).padding(.horizontal, 22)
                        }
                    }

                    if let keyFile {
                        HStack(spacing: 6) {
                            Image(systemName: "key").font(.system(size: 11))
                            Text(keyFile.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Button { self.keyFile = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .help("Quitar archivo de clave")
                        }
                        .font(.ui(12))
                        .foregroundStyle(Theme.textSecondary)
                    }

                    if touchID {
                        Button { askForFingerprint() } label: {
                            Label("Usar Touch ID", systemImage: "touchid")
                        }
                        .buttonStyle(GButtonStyle(kind: .ghost, compact: true))
                        .foregroundStyle(Theme.textSecondary)
                        .disabled(model.busy || model.touchIDPending)
                    }
                }
                .transition(.opacity)
                }
            }
            .frame(width: 400)
            .padding(.vertical, 36)
            .padding(.horizontal, 40)
            .background(
                // Un halo del color del fondo para que las piezas no se crucen con el texto.
                RadialGradient(colors: [Theme.background, Theme.background.opacity(0)], center: .center, startRadius: 120, endRadius: 330)
                    .frame(width: 760, height: 520)
            )

            let others = model.recents.filter { model.isOpen($0) && $0 != url }
            if !others.isEmpty {
                HStack(spacing: 6) {
                    Text("Siguen abiertas:").foregroundStyle(Theme.textTertiary)
                    ForEach(others, id: \.self) { other in
                        Button(other.deletingPathExtension().lastPathComponent) { model.switchTo(other) }
                            .buttonStyle(GButtonStyle(kind: .secondary, compact: true))
                    }
                }
                .font(.ui(12))
                .padding(.top, 28)
            }
            Spacer()

            HStack(spacing: 18) {
                Button("Abrir otra base de datos…") { model.showWelcome() }
                Button(keyFile == nil ? "Usar archivo de clave…" : "Cambiar archivo de clave…") { pickKeyFile() }
            }
            .buttonStyle(.plain)
            .font(.ui(12))
            .foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .animation(.easeOut(duration: 0.15), value: model.unlockError)
        .onAppear {
            focused = true
            #if DEBUG
            // Solo en la versión de pruebas: permite desbloquear la base de prueba sin teclado.
            if let test = ProcessInfo.processInfo.environment["BOVEDA_TEST_PASSWORD"] {
                password = test
                submit()
                return
            }
            #endif
            start(model.takeUnlockRequest())
        }
        // «Desbloquear» en la barra de menús con la ventana ya abierta (p. ej. la huella falló allí).
        .onChange(of: model.unlockRequestID) { _, _ in start(model.takeUnlockRequest()) }
        .onChange(of: model.unlockError) { _, error in
            // No borramos lo escrito: así se puede corregir un carácter sin reescribir la contraseña entera.
            guard error != nil, !reduceMotion else { return }
            withAnimation(.spring(response: 0.12, dampingFraction: 0.2)) { shake = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { shake = false }
        }
    }

    /// Icono de la app a la izquierda del nombre de la base.
    private var vaultTitle: some View {
        HStack(spacing: 12) {
            // El icono de macOS trae margen transparente: a 56 pt la llave se ve a la altura del nombre.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            vaultName
        }
    }

    /// Nombre de la base. Si hay más de una, al pulsarlo se elige otra.
    @ViewBuilder
    private var vaultName: some View {
        let title = Text(name).font(.ui(40, .semibold)).tracking(-1.2).foregroundStyle(Theme.text)
        if model.recents.count > 1 {
            Menu {
                ForEach(model.recents, id: \.self) { other in
                    Button {
                        if other != url { model.switchTo(other) }
                    } label: {
                        if other == url { Label(other.deletingPathExtension().lastPathComponent, systemImage: "checkmark") }
                        else { Text(other.deletingPathExtension().lastPathComponent) }
                    }
                }
                Divider()
                Button("Abrir otra base de datos…") { model.addDatabase() }
            } label: {
                HStack(spacing: 6) {
                    title
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(url.path(percentEncoded: false))
        } else {
            title.help(url.path(percentEncoded: false))
        }
    }

    /// Con Touch ID: el botón para pedir la huella (↩) y la salida a la contraseña. Mientras se descifra,
    /// la barra de progreso ocupa el sitio del botón.
    private var touchIDPrompt: some View {
        VStack(spacing: 14) {
            Button { askForFingerprint() } label: {
                Image(systemName: "touchid")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(model.touchIDPending ? Theme.text : Theme.textSecondary)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Theme.fill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.busy || model.touchIDPending)
            .accessibilityLabel("Desbloquear con Touch ID")

            Group {
                if let progress = model.unlockProgress {
                    UnlockProgressBar(progress: progress)
                } else if model.touchIDPending {
                    Text("Pon el dedo en Touch ID")
                        .font(.ui(14))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Button { askForFingerprint() } label: {
                        Label("Desbloquear con Touch ID", systemImage: "touchid")
                    }
                    .buttonStyle(GButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy)
                }
            }
            .frame(width: 280, height: 34)

            Button("Usar contraseña") { showPassword() }
                .buttonStyle(GButtonStyle(kind: .ghost, compact: true))
                .foregroundStyle(Theme.textSecondary)
                .keyboardShortcut(.cancelAction)
                .disabled(model.busy)
                .opacity(model.unlockProgress == nil ? 1 : 0)
        }
        .frame(height: 160)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }

    /// Atiende lo que se pidió al abrir esta pantalla: la huella, la contraseña o nada (tras un bloqueo).
    private func start(_ request: AppModel.UnlockStart) {
        switch request {
        case .wait: break
        case .password: showPassword()
        case .touchID:
            guard touchID else { return }
            // Si el lector no está listo, se enseña la contraseña con el botón de Touch ID a mano.
            QuickUnlock.isAvailable ? askForFingerprint() : showPassword()
        }
    }

    private func askForFingerprint() {
        guard !model.touchIDPending, !model.busy else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { usePassword = false }
        Task {
            if await model.unlockWithTouchID(url: url) == false, model.lockedURL == url { showPassword() }
        }
    }

    private func showPassword() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { usePassword = true }
        DispatchQueue.main.async { focused = true }  // El campo aún no existía: se enfoca al aparecer.
    }

    /// Campo grande con el botón de entrar dentro, como la pantalla de inicio de sesión del Mac.
    private var passwordField: some View {
        HStack(spacing: 4) {
            Group {
                if reveal { TextField("Contraseña maestra", text: $password) } else { SecureField("Contraseña maestra", text: $password) }
            }
            .textFieldStyle(.plain)
            .font(.ui(16))
            .focused($focused)
            .onSubmit(submit)
            .accessibilityLabel("Contraseña maestra")
            .padding(.leading, 22)

            if !password.isEmpty {
                Button { reveal.toggle() } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(reveal ? "Ocultar" : "Mostrar")
            }

            Button(action: submit) {
                ZStack {
                    Circle().fill(canSubmit ? Theme.primary : Theme.selected)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(canSubmit ? Theme.onPrimary : Theme.textTertiary)
                }
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .help("Desbloquear (↩)")
            .accessibilityLabel(model.busy ? "Desbloqueando" : "Desbloquear")
            .padding(.trailing, 6)
        }
        .frame(height: 54)
        .background(Capsule().fill(Theme.background))
        .overlay(Capsule().strokeBorder(focused ? Theme.borderStrong : Theme.border))
        .shadow(color: .black.opacity(0.07), radius: 18, y: 6)
        .animation(.easeOut(duration: 0.12), value: focused)
        .animation(.easeOut(duration: 0.12), value: canSubmit)
    }

    private func submit() {
        guard canSubmit else { return }
        let typed = password
        Task { await model.unlock(url: url, password: typed, keyFile: keyFile) }
    }

    private func pickKeyFile() {
        let panel = NSOpenPanel()
        panel.message = L("Elige el archivo de clave")
        if panel.runModal() == .OK { keyFile = panel.url }
    }
}

struct CreateVaultSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = L("Contraseñas")
    @State private var password = ""
    @State private var confirm = ""

    private var strength: PasswordStrength { .of(password) }
    private var valid: Bool { !name.isEmpty && password.count >= 8 && password == confirm }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nueva base de datos").font(.ui(18, .semibold))
            Text("Se guarda como un archivo .kdbx estándar, que puedes abrir en el móvil. Si olvidas la contraseña maestra no hay forma de recuperarla.")
                .font(.ui(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledField("Nombre") { GField(focused: false) { TextField("", text: $name) } }
            LabeledField(L("Contraseña maestra")) {
                GField(focused: false) { SecureField("", text: $password).font(.mono(13)) }
            }
            StrengthBar(fraction: password.isEmpty ? 0 : strength.fraction, label: password.count < 8 ? L("Mínimo 8 caracteres") : strength.label)
            LabeledField(L("Repítela")) {
                GField(focused: false) { SecureField("", text: $confirm).font(.mono(13)) }
            }
            if !confirm.isEmpty && confirm != password {
                Text("No coinciden").font(.ui(12)).foregroundStyle(Theme.red)
            }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(GButtonStyle(kind: .secondary))
                Button("Crear…") { save() }
                    .buttonStyle(GButtonStyle(kind: .primary))
                    .disabled(!valid)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(Theme.background)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "kdbx") ?? .data]
        panel.nameFieldStringValue = name + ".kdbx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let n = name, p = password
        dismiss()
        Task { await model.create(at: url, name: n, password: p) }
    }
}

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.ui(12, .medium)).foregroundStyle(Theme.textSecondary)
            content
        }
    }
}

struct StrengthBar: View {
    let fraction: Double
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hover)
                    Capsule().fill(Theme.strengthColor(fraction)).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 4)
            if !label.isEmpty {
                Text(label).font(.ui(11, .medium)).foregroundStyle(Theme.textSecondary).fixedSize()
            }
        }
        .animation(.easeOut(duration: 0.2), value: fraction)
    }
}

/// Barra de desbloqueo: sube hasta el 99 % en lo que tardó la base la última vez y llega al 100 % al abrir.
struct UnlockProgressBar: View {
    let progress: AppModel.UnlockProgress
    var showsLabel = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: progress.done)) { context in
            let fraction = progress.fraction(at: context.date)
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.selected)
                        Capsule().fill(Theme.primary).frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: showsLabel ? 4 : 3)
                if showsLabel { HStack {
                    Text(progress.done ? "Abriendo…" : "Descifrando…")
                    Spacer()
                    Text("\(Int((fraction * 100).rounded(.down))) %").monospacedDigit()
                }
                .font(.ui(11, .medium))
                .foregroundStyle(Theme.textTertiary) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Descifrando")
            .accessibilityValue("\(Int(fraction * 100)) %")
        }
        .animation(.easeOut(duration: 0.18), value: progress.done)
    }
}
