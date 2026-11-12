import AppKit
import BovedaCore
import SwiftUI

@main
struct BovedaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Hush", id: "main") {
            RootView()
                .environment(model)
                // Mínimos según la pantalla: el desbloqueo cabe en una ventana pequeña; la principal necesita sus tres columnas.
                .frame(minWidth: model.phase == .unlocked ? 980 : 480, minHeight: model.phase == .unlocked ? 600 : 460)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1280, height: 780)
        .commands { AppCommands(model: model) }

        // Entrada abierta en su propia ventana (se puede fijar encima de todo).
        WindowGroup("Entrada", id: "entry", for: PopOutTarget.self) { $target in
            if let target {
                PopOutEntryView(target: target)
                    .environment(model)
                    .tint(Theme.text)
            }
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: false))

        Settings {
            SettingsView()
                .environment(model)
                .tint(Theme.text)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if Preferences.hideDockIcon { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Adjuntos descifrados que pudo dejar una salida brusca (caída, apagón): fuera antes de nada.
        AttachmentTemp.clear()
        MainActor.assumeIsolated {
            AppModel.applyAppearance()
            GlobalHotkey.register()
            BrowserBridge.shared.start()
        }
        #if DEBUG
        // Solo en la versión de pruebas: abre la búsqueda rápida sola para poder revisarla.
        if ProcessInfo.processInfo.environment["HUSH_TEST_QUICK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                MainActor.assumeIsolated {
                    QuickSearchPanel.useWindowScreen = true
                    QuickSearchPanel.show()
                }
            }
        }
        #endif
    }

    /// Con el icono de la barra de menús, cerrar la ventana no cierra la app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(Preferences.menuBarIcon || Preferences.hideDockIcon)
    }

    /// Clic en el icono del Dock sin ventanas: vuelve a abrir la principal.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppModel.shared?.showMainWindow() } }
        return true
    }

    /// Antes de salir espera a que se termine de escribir lo pendiente, para no perder la última edición.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = MainActor.assumeIsolated { AppModel.shared }
        guard let model else { return .terminateNow }
        // Si un guardado falló (o falla ahora), los cambios se dejan en una copia aparte antes de salir.
        // Si no se pueden poner a salvo, no se sale: el aviso explica cómo guardarlos a mano.
        if !MainActor.assumeIsolated({ model.hasPendingSaves }) {
            return MainActor.assumeIsolated { model.rescueUnsaved(modal: true) } ? .terminateNow : .terminateCancel
        }
        Task { @MainActor in
            await model.flushSaves()
            NSApp.reply(toApplicationShouldTerminate: model.rescueUnsaved(modal: true))
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Clipboard.clearIfOurs() }
        AttachmentTemp.clear()
    }
}

/// Atajos copiados de KeePassXC (Ctrl → ⌘).
struct AppCommands: Commands {
    let model: AppModel
    @FocusedValue(\.browserFocus) private var browserFocus

    private var entriesFocused: Bool { browserFocus == .entries }
    /// ⌘↑/⌘↓ solo ordenan grupos si el foco está en la lista, no en un campo de texto.
    private var listFocused: Bool { browserFocus == .entries || browserFocus == .groups }

    private var unlocked: Bool { model.phase == .unlocked }
    @Environment(\.openWindow) private var openWindow

    private func openSelectedInWindow() {
        guard let id = model.selectedEntryID, let url = model.vault?.url else { return }
        openWindow(id: "entry", value: PopOutTarget(entryID: id, vault: url))
    }
    private var hasEntry: Bool { unlocked && model.selectedEntry != nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nueva entrada") { model.newEntry() }
                .keyboardShortcut("n")
                .disabled(!unlocked)
            Button("Nueva tarjeta") { model.newEntry(.card) }
                .disabled(!unlocked)
            Button("Nueva nota segura") { model.newEntry(.note) }
                .disabled(!unlocked)
            Button("Nuevo grupo") { model.requestNewGroup() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!unlocked)
            Button("Nueva base de datos…") {
                // Solo se bloquea la activa: cerrar saltaría a otra base abierta e interrumpiría la creación.
                guard model.lock() else { return }
                model.showWelcome()
                model.wantsCreate = true
            }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Abrir base de datos…") { model.addDatabase() }
                .keyboardShortcut("o")
            Button("Cerrar base de datos") { model.closeDatabase() }
                .keyboardShortcut("w")
                .disabled(!unlocked)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Guardar") { model.save() }
                .keyboardShortcut("s")
                .disabled(!unlocked)
            Button("Guardar una copia como…") { model.saveCopyPanel() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!unlocked)
            Divider()
            Button("Exportar a CSV…") { model.export(withAttachments: false) }.disabled(!unlocked)
            Button("Exportar con adjuntos (.zip)…") { model.export(withAttachments: true) }.disabled(!unlocked)
        }
        // ⌘C copia la contraseña cuando la lista de entradas tiene el foco; en un campo de texto, copia normal.
        CommandGroup(replacing: .pasteboard) {
            Button("Cortar") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                .keyboardShortcut("x")
            Button(entriesFocused && hasEntry ? L("Copiar ") + (model.selectedEntry?.entry.kind ?? .login).mainValueName : L("Copiar")) {
                if entriesFocused && hasEntry { model.copyPassword() } else { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
            }
            .keyboardShortcut("c")
            Button("Pegar") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                .keyboardShortcut("v")
            Button("Seleccionar todo") {
                if entriesFocused { model.selectAllEntries() } else { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
            }
            .keyboardShortcut("a")
        }
        CommandMenu("Entrada") {
            Button("Copiar usuario") { model.copyUserName() }.keyboardShortcut("b").disabled(!hasEntry)
            Button(L("Copiar ") + (model.selectedEntry?.entry.kind ?? .login).mainValueName) { model.copyPassword() }.disabled(!hasEntry)
            Button("Copiar web") { model.copyURL() }.keyboardShortcut("u").disabled(!hasEntry)
            Button("Abrir web") { model.openURL() }.keyboardShortcut("u", modifiers: [.command, .shift]).disabled(!hasEntry)
            Button("Copiar código 2FA") { model.copyTOTP() }.keyboardShortcut("t").disabled(!hasEntry)
            Button("Copiar contraseña y 2FA") { model.copyPasswordAndTOTP() }.keyboardShortcut("y").disabled(!hasEntry)
            Button("Mostrar código 2FA") { model.showTOTP() }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(!hasEntry)
            Button("Copiar contraseña y abrir web") { if let e = model.selectedEntry?.entry { model.copyPasswordAndOpenURL(e) } }
                .keyboardShortcut("u", modifiers: [.command, .option]).disabled(!hasEntry)
            Button("Copiar usuario y contraseña") { if let e = model.selectedEntry?.entry { model.copyUserAndPassword(e) } }.disabled(!hasEntry)
            Button("Copiar todos los campos") { if let e = model.selectedEntry?.entry { model.copyAllFields(e) } }.disabled(!hasEntry)
            Divider()
            Button("Copiar entrada") { if let id = model.selectedEntryID { model.copyEntry(id) } }
                .keyboardShortcut("c", modifiers: [.command, .option]).disabled(!hasEntry)
            Button(model.entryClipboard.map { "Pegar «\($0.title)»" } ?? "Pegar entrada") { model.pasteEntry() }
                .keyboardShortcut("v", modifiers: [.command, .option]).disabled(!unlocked || model.entryClipboard == nil)
            Divider()
            Button("Abrir en otra ventana") { openSelectedInWindow() }
                .keyboardShortcut("o", modifiers: [.command, .option]).disabled(!hasEntry)
            Button("Historial…") { model.sheet = .history }
                .keyboardShortcut("h", modifiers: [.command, .shift]).disabled(!hasEntry || (model.selectedEntry?.entry.history.isEmpty ?? true))
            Divider()
            Button("Editar") { if let id = model.selectedEntryID { model.edit(id) } }.keyboardShortcut("e").disabled(!hasEntry)
            Button("Duplicar") { if let id = model.selectedEntryID { model.duplicate(id) } }.keyboardShortcut("d").disabled(!hasEntry)
            Button("Añadir o quitar de favoritos") { if let id = model.selectedEntryID { model.toggleFavorite(id) } }.disabled(!hasEntry)
            Button("Ir al grupo de la entrada") { model.jumpToGroup() }.keyboardShortcut("j", modifiers: [.command, .shift]).disabled(!hasEntry)
            Divider()
            Button(model.deleteTitle(for: model.selectedIDs)) { model.deleteSelected() }.keyboardShortcut(.delete).disabled(!hasEntry)
        }
        CommandMenu("Base de datos") {
            Button("Bloquear") { model.lock() }.keyboardShortcut("l").disabled(!unlocked)
            Button("Bloquear todas") { model.lockAll() }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(model.openURLs.isEmpty)
            Divider()
            Button("Añadir base de datos…") { model.addDatabase() }
            ForEach(Array(model.recents.prefix(9).enumerated()), id: \.element) { index, url in
                Button(url.deletingPathExtension().lastPathComponent) { model.switchTo(index: index) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
            Divider()
            Button("Ajustes de la base de datos…") { model.sheet = .databaseSettings }.keyboardShortcut(",", modifiers: [.command, .shift]).disabled(!unlocked)
            Button("Informe de contraseñas…") { model.sheet = .report }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!unlocked)
            Button("Descargar los logos de todas las webs") { model.fetchAllFavicons() }.disabled(!unlocked)
            Divider()
            Button("Ordenar grupos A-Z") { model.sortGroups(ascending: true) }.keyboardShortcut(.downArrow).disabled(!unlocked || !listFocused || model.editing != nil || model.sheet != nil)
            Button("Ordenar grupos Z-A") { model.sortGroups(ascending: false) }.keyboardShortcut(.upArrow).disabled(!unlocked || !listFocused || model.editing != nil || model.sheet != nil)
        }
        CommandGroup(after: .toolbar) {
            Button(model.revealPassword ? "Ocultar contraseñas" : "Mostrar contraseñas") { model.revealPassword.toggle() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button(model.hideUsernames ? "Mostrar usuarios" : "Ocultar usuarios") { model.hideUsernames.toggle() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Ir a los grupos") { model.focusRequest = .groups }.keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF1FunctionKey)!)), modifiers: [])
            Button("Ir a las entradas") { model.focusRequest = .entries }.keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), modifiers: [])
            Button("Buscar") { model.searchFocusTrigger += 1 }.keyboardShortcut("f")
            Button("Ir al buscador") { model.searchFocusTrigger += 1 }.keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF3FunctionKey)!)), modifiers: [])
            Divider()
        }
        CommandGroup(after: .windowSize) {
            Button("Ocultar ventana") { NSApp.hide(nil) }.keyboardShortcut("m", modifiers: [.command, .shift])
            Toggle("Mantener encima de todo", isOn: Binding(get: { model.alwaysOnTop }, set: { model.alwaysOnTop = $0 }))
            Button("Búsqueda rápida") { QuickSearchPanel.show() }
        }
        CommandGroup(replacing: .help) {
            Button("Atajos de teclado") { model.sheet = .shortcuts }.keyboardShortcut("/")
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        ZStack {
            Theme.background.ignoresSafeArea()
            switch model.phase {
            case .welcome: WelcomeView()
            case let .locked(url): UnlockView(url: url).id(url)
            case .unlocked: MainView()
            }
        }
        .font(.ui(13))
        .foregroundStyle(Theme.text)
        .tint(Theme.text)
        .background(WindowReader { model.mainWindow = $0 })
        .onChange(of: model.phase == .unlocked) { model.fitWindowToPhase() }
        .onAppear {
            model.openMainWindowAction = { [openWindow] in openWindow(id: "main") }
            model.openSettingsAction = { [openSettings] in openSettings() }
            MenuBarItem.shared.install(model: model)
        }
        .overlay {
            if let url = model.switchedTo { SwitchHUD(url: url) }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.ui(13, .medium))
                    .foregroundStyle(Theme.onPrimary)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.primary))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert(item: $model.alert) { alert in
            if alert.reload {
                return Alert(title: Text(alert.title), message: Text(alert.message),
                             primaryButton: .default(Text("Recargar")) { Task { await model.reloadFromDisk() } },
                             secondaryButton: .cancel(Text("Ahora no")))
            }
            return Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }
}

/// Da acceso a la NSWindow de una vista de SwiftUI (para fijarla encima de todo).
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let window = nsView.window { onWindow(window) } }
    }
}
