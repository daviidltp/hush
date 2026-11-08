import AppKit
import BovedaCore
import KDBXKit
import SwiftUI

/// Cabecera común de las hojas: título, subtítulo y botón de cerrar.
private struct SheetHeader: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.ui(18, .semibold))
                if let subtitle { Text(subtitle).font(.ui(12)).foregroundStyle(Theme.textSecondary) }
            }
            Spacer()
            IconButton(symbol: "xmark", help: "Cerrar", size: 28) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }
}

// MARK: - Atajos

struct ShortcutsSheet: View {
    static let groups: [(String, [(String, String)])] = [
        ("Base de datos", [
            ("Abrir base de datos", "⌘O"), ("Guardar", "⌘S"), ("Guardar una copia como", "⇧⌘S"),
            ("Nueva base de datos", "⇧⌘N"), ("Cerrar base de datos", "⌘W"), ("Bloquear", "⌘L"),
            ("Bloquear todas", "⇧⌘L"), ("Cambiar a la base 1…9", "⌘1…⌘9"), ("Ajustes de la base de datos", "⇧⌘,"), ("Informe de contraseñas", "⇧⌘R"),
            ("Ajustes de la app", "⌘,"), ("Salir", "⌘Q"),
        ]),
        ("Entradas", [
            ("Nueva entrada", "⌘N"), ("Nuevo grupo", "⌥⌘N"), ("Editar entrada", "↩ o ⌘E"), ("Mover a la papelera", "⌫ o ⌘⌫"),
            ("Duplicar", "⌘D"), ("Copiar usuario", "⌘B"), ("Copiar contraseña", "⌘C"), ("Copiar web", "⌘U"),
            ("Abrir web", "⇧⌘U"), ("Copiar código 2FA", "⌘T"), ("Copiar contraseña y 2FA", "⌘Y"),
            ("Mostrar código 2FA", "⇧⌘T"), ("Ir al grupo de la entrada", "⇧⌘J"),
            ("Copiar contraseña y abrir web", "⌥⌘U"), ("Copiar entrada", "⌥⌘C"), ("Pegar entrada", "⌥⌘V"),
            ("Abrir en otra ventana", "⌥⌘O"), ("Historial", "⇧⌘H"), ("Seleccionar varias", "⌘ clic · ⇧ clic"),
        ]),
        ("Vista", [
            ("Ordenar grupos A-Z", "⌘↓"), ("Ordenar grupos Z-A", "⌘↑"), ("Mostrar u ocultar contraseñas", "⇧⌘C"),
            ("Mostrar u ocultar usuarios", "⇧⌘B"), ("Ir a los grupos", "F1"), ("Ir a las entradas", "F2"),
            ("Buscar", "⌘F o F3"), ("Borrar la búsqueda", "esc"), ("Minimizar", "⌘M"), ("Ocultar ventana", "⇧⌘M"),
            ("Ver estos atajos", "⌘/"), ("Búsqueda rápida (en cualquier app)", "⇧⌘P"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "Atajos de teclado")
            ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    ForEach(Self.groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.0).font(.ui(12, .semibold)).foregroundStyle(Theme.textSecondary)
                            ForEach(group.1, id: \.0) { item in
                                HStack {
                                    Text(item.0).font(.ui(13))
                                    Spacer(minLength: 12)
                                    Kbd(text: item.0.hasPrefix("Búsqueda rápida") ? (QuickSearchHotkey(rawValue: Preferences.quickSearchHotkey) ?? .shiftCommandP).label : item.1)
                                }
                            }
                        }
                        .frame(width: 230)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 800, height: 600)
    }
}

// MARK: - Informe de contraseñas

struct ReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let entries = model.vault.map(model.auditableEntries) ?? []
        let report = PasswordReport(entries: entries)
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "Informe de contraseñas",
                        subtitle: report.issueCount == 0 ? "Todo en orden: ninguna contraseña débil, repetida ni caducada." : "\(entries.count) entradas revisadas en este Mac. Nada sale del ordenador.")
            HStack(spacing: 10) {
                stat("Débiles", report.weak.count, Theme.red)
                stat("Repetidas", report.reused.count, Theme.amber)
                stat("Vacías", report.empty.count, Theme.textSecondary)
                stat("Caducadas", report.expired.count, Theme.textSecondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Débiles", report.weak)
                    section("Repetidas", report.reused)
                    section("Sin contraseña", report.empty)
                    section("Caducadas", report.expired)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 560)
    }

    private func stat(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.ui(22, .semibold)).foregroundStyle(value > 0 ? color : Theme.text)
            Text(label).font(.ui(12)).foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.fill))
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [PasswordReport.Item]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.ui(12, .semibold)).foregroundStyle(Theme.textSecondary)
                ForEach(items) { item in
                    Button {
                        model.search = ""
                        model.sidebar = .all
                        model.selectedEntryID = item.entry.uuid
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            EntryIcon(entry: item.entry, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.entry.title.isEmpty ? "Sin título" : item.entry.title).font(.ui(13, .medium))
                                Text(item.entry.userName).font(.ui(11)).foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Badge(text: item.detail)
                        }
                        .padding(8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Código 2FA grande

struct TOTPSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            SheetHeader(title: model.selectedEntry?.entry.title ?? "Código 2FA")
            if let entry = model.selectedEntry?.entry, let totp = TOTP.from(entry) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = totp.secondsRemaining(at: context.date)
                    VStack(spacing: 14) {
                        Text(totp.code(at: context.date))
                            .font(.mono(40, .medium))
                            .tracking(4)
                            .foregroundStyle(remaining <= 5 ? Theme.red : Theme.text)
                            .contentTransition(.numericText())
                        ProgressView(value: Double(remaining), total: Double(totp.period))
                            .tint(remaining <= 5 ? Theme.red : Theme.text)
                            .frame(width: 220)
                        Text("Caduca en \(remaining) s").font(.ui(12)).foregroundStyle(Theme.textSecondary)
                        Button("Copiar") { model.copy(totp.code(), label: "Código 2FA") }
                            .buttonStyle(GButtonStyle(kind: .primary))
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

// MARK: - Ajustes de la base de datos

struct DatabaseSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var recycleBin = true
    @State private var historyLimit = 10
    @State private var unlimitedHistory = false
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var changingPassword = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(title: "Ajustes de la base de datos", subtitle: model.vault?.url.lastPathComponent)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledField("Nombre") { GField(focused: false) { TextField("", text: $name) } }
                    LabeledField("Descripción") { GField(focused: false) { TextField("Opcional", text: $description) } }
                    Toggle("Usar papelera (lo borrado se puede recuperar)", isOn: $recycleBin).toggleStyle(.switch).controlSize(.small)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Historial ilimitado", isOn: $unlimitedHistory).toggleStyle(.switch).controlSize(.small)
                        if !unlimitedHistory {
                            Stepper("Guardar \(historyLimit) versiones por entrada", value: $historyLimit, in: 0...100).font(.ui(13))
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Guardar cambios") {
                            model.updateDatabase(name: name, description: description, recycleBin: recycleBin, historyLimit: unlimitedHistory ? nil : historyLimit)
                            dismiss()
                        }
                        .buttonStyle(GButtonStyle(kind: .primary))
                        .disabled(changingPassword || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Divider().padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Cambiar contraseña maestra").font(.ui(14, .semibold))
                        Text("En el móvil te pedirá la nueva la próxima vez. Antes de cambiarla se guarda una copia del archivo actual.")
                            .font(.ui(12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        GField(focused: false) { SecureField("Nueva contraseña", text: $newPassword).font(.mono(13)) }
                        let strength = PasswordStrength.of(newPassword)
                        StrengthBar(fraction: newPassword.isEmpty ? 0 : strength.fraction, label: newPassword.count < 8 ? "Mínimo 8 caracteres" : strength.label)
                        GField(focused: false) { SecureField("Repítela", text: $confirmPassword).font(.mono(13)) }
                        if !confirmPassword.isEmpty && confirmPassword != newPassword {
                            Text("No coinciden").font(.ui(12)).foregroundStyle(Theme.red)
                        }
                        HStack {
                            Spacer()
                            Button {
                                changingPassword = true
                                let password = newPassword
                                Task {
                                    let ok = await model.changeMasterPassword(to: password)
                                    changingPassword = false
                                    if ok { dismiss() }
                                }
                            } label: {
                                // Mismo ancho en los dos estados: el botón no cambia de tamaño al pulsarlo.
                                ZStack {
                                    Text("Cambiar contraseña").opacity(changingPassword ? 0 : 1)
                                    if changingPassword { ProgressView().controlSize(.small) }
                                }
                            }
                            .buttonStyle(GButtonStyle(kind: .secondary))
                            .disabled(changingPassword || newPassword.count < 8 || newPassword != confirmPassword)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 480, height: 600)
        .interactiveDismissDisabled(changingPassword)
        .onAppear {
            guard let meta = model.vault?.content.database.meta else { return }
            name = model.vault?.name ?? ""
            description = meta.databaseDescription ?? ""
            recycleBin = meta.recycleBinEnabled ?? true
            switch meta.historyMaxItems {
            case .unlimited: unlimitedHistory = true
            case let .value(n): historyLimit = Int(n)
            case nil: historyLimit = 10
            }
        }
    }
}

// MARK: - Ajustes de la app (⌘,)

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Apariencia", systemImage: "circle.lefthalf.filled") { AppearanceSettings() }
            Tab("Seguridad", systemImage: "lock.shield") { SecuritySettings() }
            Tab("Auditoría", systemImage: "checkmark.shield") { AuditSettings() }
            Tab("Navegadores", systemImage: "globe") { BrowserSettings() }
            Tab("Copias", systemImage: "clock.arrow.circlepath") { BackupSettings() }
        }
        .frame(width: 560, height: 480)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var openLast = Preferences.openLastDatabase
    @State private var favicons = Preferences.showFavicons
    @State private var openAtLogin = AppModel.opensAtLogin
    @State private var hotkey = QuickSearchHotkey(rawValue: Preferences.quickSearchHotkey) ?? .shiftCommandP
    @State private var showShortcuts = false
    @State private var hotkeyError: String? = GlobalHotkey.failed.map { "\($0.label) ya lo usa otra app o el sistema. Elige otro." }
    @State private var revertedTo: QuickSearchHotkey?

    var body: some View {
        Form {
            Section {
                Toggle("Abrir la última base de datos al iniciar", isOn: $openLast)
                Toggle("Abrir Hush al iniciar sesión en el Mac", isOn: $openAtLogin)
            }
            Section {
                Picker("Búsqueda rápida desde cualquier app", selection: $hotkey) {
                    ForEach(QuickSearchHotkey.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } footer: {
                if let hotkeyError {
                    Text(hotkeyError).font(.ui(11)).foregroundStyle(Theme.red)
                } else {
                    Text("Abre una ventanita para buscar y copiar una contraseña sin salir de lo que estás haciendo.")
                        .font(.ui(11)).foregroundStyle(Theme.textTertiary)
                }
            }
            Section {
                Toggle("Mostrar el logo de la web de cada entrada", isOn: $favicons)
                if favicons {
                    LabeledContent("Logos guardados") {
                        Button("Borrar") { FaviconStore.shared.clearCache() }
                    }
                }
            } footer: {
                Text("Hush pide el logo directamente a cada web, sin pasar por otros servicios. Solo se envía el dominio, nunca tus datos.")
                    .font(.ui(11)).foregroundStyle(Theme.textTertiary)
            }
            Section("Atajos") {
                LabeledContent("Atajos de teclado") {
                    Button("Ver atajos…") { showShortcuts = true }
                        .sheet(isPresented: $showShortcuts) { ShortcutsSheet() }
                }
            }
            Section("Bases de datos") {
                if model.recents.isEmpty {
                    Text("Ninguna").foregroundStyle(Theme.textSecondary)
                }
                ForEach(model.recents, id: \.self) { url in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(url.deletingPathExtension().lastPathComponent)
                            Text(url.deletingLastPathComponent().path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.ui(11)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Quitar") { model.removeRecent(url) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: openLast) { _, v in Preferences.openLastDatabase = v }
        .onChange(of: hotkey) { _, v in
            guard v != revertedTo else { revertedTo = nil; return }  // Es la vuelta atrás de abajo: se mantiene el aviso.
            if GlobalHotkey.register(v) {
                Preferences.quickSearchHotkey = v.rawValue
                hotkeyError = nil
            } else {
                // Se vuelve al atajo que funcionaba y se explica por qué.
                hotkeyError = "\(v.label) ya lo usa otra app o el sistema. Elige otro."
                let previous = QuickSearchHotkey(rawValue: Preferences.quickSearchHotkey) ?? .shiftCommandP
                GlobalHotkey.register(previous)
                revertedTo = previous
                hotkey = previous
            }
        }
        .onChange(of: openAtLogin) { _, v in
            do { try AppModel.setOpensAtLogin(v) } catch {
                model.alert = AppModel.AlertMessage(title: "No se ha podido cambiar", message: error.localizedDescription)
                openAtLogin = AppModel.opensAtLogin
            }
        }
        .onChange(of: favicons) { _, v in
            Preferences.showFavicons = v
            if !v { FaviconStore.shared.clearCache() }
        }
    }
}

private struct SecuritySettings: View {
    @Environment(AppModel.self) private var model
    @State private var autoLock = Preferences.autoLockMinutes
    @State private var clipboard = Preferences.clipboardSeconds
    @State private var touchID = Preferences.touchIDEnabled
    @State private var masterDays = Preferences.masterPasswordDays
    @State private var lockOnSleep = Preferences.lockOnSleep

    var body: some View {
        Form {
            Section("Bloqueo") {
                Picker("Bloquear tras inactividad", selection: $autoLock) {
                    Text("1 minuto").tag(1)
                    Text("5 minutos").tag(5)
                    Text("15 minutos").tag(15)
                    Text("1 hora").tag(60)
                    Text("Nunca").tag(0)
                }
                Toggle("Bloquear al dormir o bloquear la pantalla", isOn: $lockOnSleep)
                Picker("Borrar el portapapeles tras", selection: $clipboard) {
                    Text("15 segundos").tag(15)
                    Text("30 segundos").tag(30)
                    Text("1 minuto").tag(60)
                    Text("Nunca").tag(0)
                }
            }
            Section {
                Toggle("Recordar la contraseña maestra con Touch ID", isOn: $touchID)
                    .disabled(!QuickUnlock.isAvailable)
                Picker("Pedir la contraseña maestra cada", selection: $masterDays) {
                    Text("Nunca").tag(0)
                    Text("7 días").tag(7)
                    Text("14 días").tag(14)
                    Text("30 días").tag(30)
                }
                .disabled(!touchID)
            } header: {
                Text("Touch ID")
            } footer: {
                Text(QuickUnlock.isAvailable
                     ? "La clave se guarda cifrada en el Secure Enclave del Mac y solo se abre con tu huella. Si cambias las huellas, se pide de nuevo la contraseña."
                     : "Este Mac no tiene Touch ID disponible.")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: autoLock) { _, v in Preferences.autoLockMinutes = v }
        .onChange(of: clipboard) { _, v in Preferences.clipboardSeconds = v }
        .onChange(of: lockOnSleep) { _, v in Preferences.lockOnSleep = v }
        .onChange(of: masterDays) { _, v in Preferences.masterPasswordDays = v }
        .onChange(of: touchID) { _, enabled in
            Preferences.touchIDEnabled = enabled
            if !enabled { for url in model.recents { QuickUnlock.forget(url) } }
            else if let vault = model.vault { try? QuickUnlock.enroll(vault.unlock, for: vault.url) }
        }
    }
}

private struct BackupSettings: View {
    var body: some View {
        Form {
            Section {
                Text("Antes de cada guardado se copia la versión anterior del archivo. Se guardan las 30 últimas de cada base de datos, fuera de iCloud.")
                    .foregroundStyle(Theme.textSecondary)
                LabeledContent("Carpeta") {
                    Button("Abrir en Finder") {
                        let dir = BackupStore.default.directory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model
    @State private var mode = Preferences.appearance
    @State private var hideDock = Preferences.hideDockIcon

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Tema") {
                Picker("Apariencia", selection: $mode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("Icono en la barra de menús", isOn: $model.menuBarIcon)
                    .disabled(hideDock)
                Toggle("Ocultar el icono del Dock", isOn: $hideDock)
                Toggle("Mantener la ventana encima de todo", isOn: $model.alwaysOnTop)
            } header: {
                Text("Ventana")
            } footer: {
                Text(hideDock ? "Sin icono en el Dock, Hush se abre desde la barra de menús o con el atajo de búsqueda rápida." : "Con el icono de la barra de menús, cerrar la ventana no cierra Hush.")
                    .font(.ui(11)).foregroundStyle(Theme.textTertiary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: mode) { _, v in
            Preferences.appearance = v
            AppModel.applyAppearance(v)
        }
        .onChange(of: hideDock) { _, v in
            Preferences.hideDockIcon = v
            if v { model.menuBarIcon = true }
            AppModel.applyDockIcon(hidden: v)
        }
    }
}

private struct AuditSettings: View {
    @Environment(AppModel.self) private var model
    @State private var breaches = Preferences.checkBreaches
    @State private var twoFactor = Preferences.check2FA
    @State private var simpleLoginKey = SimpleLogin.apiKey ?? ""

    var body: some View {
        Form {
            Section {
                Toggle("Comprobar si las contraseñas han salido en filtraciones", isOn: $breaches)
            } footer: {
                Text("Usa Have I Been Pwned. Tu contraseña nunca sale del Mac: solo se envían los 5 primeros caracteres de su huella cifrada y la comparación se hace aquí.")
                    .font(.ui(11)).foregroundStyle(Theme.textTertiary)
            }
            Section {
                Toggle("Avisar de webs que permiten 2FA y no lo tienes", isOn: $twoFactor)
            } footer: {
                Text("Se descarga una vez por semana la lista pública de 2fa.directory. No se envía nada tuyo.")
                    .font(.ui(11)).foregroundStyle(Theme.textTertiary)
            }
            Section {
                SecureField("Clave de la API", text: $simpleLoginKey)
                    .onSubmit { SimpleLogin.apiKey = simpleLoginKey }
                HStack {
                    Spacer()
                    Button("Guardar clave") { SimpleLogin.apiKey = simpleLoginKey }
                        .disabled(simpleLoginKey == (SimpleLogin.apiKey ?? ""))
                }
            } header: {
                Text("Alias de email (SimpleLogin)")
            } footer: {
                Text("Con la clave, el editor muestra un botón @ junto al usuario para crear un email distinto para cada web. La clave se guarda en el llavero del Mac. La sacas en app.simplelogin.io → API Keys.")
                    .font(.ui(11)).foregroundStyle(Theme.textTertiary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: breaches) { _, v in
            Preferences.checkBreaches = v
            if v { model.scheduleAuditChecks() } else { AuditServices.shared.reset() }
            model.invalidateAudit()
        }
        .onChange(of: twoFactor) { _, v in
            Preferences.check2FA = v
            if v { AuditServices.shared.loadTwoFactorList() }
            model.invalidateAudit()
        }
    }
}
