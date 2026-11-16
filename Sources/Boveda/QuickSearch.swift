import AppKit
import BovedaCore
import Carbon.HIToolbox
import KDBXKit
import SwiftUI

// MARK: - Atajo global

/// Combinaciones que se pueden elegir para abrir la búsqueda rápida desde cualquier app.
enum QuickSearchHotkey: Int, CaseIterable {
    case shiftCommandP = 4, shiftCommandSpace = 0, controlOptionSpace = 1, optionCommandP = 2, off = 3

    var label: String {
        switch self {
        case .shiftCommandP: return "⇧⌘P"
        case .shiftCommandSpace: return "⇧⌘Espacio"
        case .controlOptionSpace: return "⌃⌥Espacio"
        case .optionCommandP: return "⌥⌘P"
        case .off: return L("Desactivado")
        }
    }

    fileprivate var carbon: (key: UInt32, modifiers: UInt32)? {
        switch self {
        case .shiftCommandP: return (UInt32(kVK_ANSI_P), UInt32(shiftKey | cmdKey))
        case .shiftCommandSpace: return (UInt32(kVK_Space), UInt32(shiftKey | cmdKey))
        case .controlOptionSpace: return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .optionCommandP: return (UInt32(kVK_ANSI_P), UInt32(optionKey | cmdKey))
        case .off: return nil
        }
    }
}

/// Registra el atajo con Carbon: funciona en todo el sistema sin pedir permisos de accesibilidad.
@MainActor
enum GlobalHotkey {
    private static var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    /// El último atajo que el sistema no dejó usar (también al arrancar), para explicarlo en Ajustes.
    static var failed: QuickSearchHotkey?

    /// Devuelve false si el sistema no deja usar esa combinación (por ejemplo, porque la usa otra app).
    @discardableResult
    static func register(_ hotkey: QuickSearchHotkey = QuickSearchHotkey(rawValue: Preferences.quickSearchHotkey) ?? .shiftCommandP) -> Bool {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let combo = hotkey.carbon else { failed = nil; return true }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { QuickSearchPanel.toggle() } }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4855_5348), id: 1) // "HUSH"
        let status = RegisterEventHotKey(combo.key, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { ref = nil }
        failed = status == noErr ? nil : hotkey
        return status == noErr
    }
}

// MARK: - Panel flotante

/// Ventana tipo Spotlight. No activa Hush, así que al copiar puedes pegar directamente en la app de antes.
final class QuickSearchPanel: NSPanel {
    private static var shared: QuickSearchPanel?
    /// Solo para pruebas: abrir en la pantalla de la ventana principal en vez de en la activa.
    static var useWindowScreen = false

    override var canBecomeKey: Bool { true }

    @MainActor
    static func toggle() {
        if let panel = shared, panel.isVisible { panel.close(); return }
        show()
    }

    @MainActor
    static func show() {
        guard let model = AppModel.shared else { return }
        let panel = shared ?? QuickSearchPanel(model: model)
        shared = panel
        panel.reset(model: model)
        let screen = (useWindowScreen ? model.mainWindow?.screen : nil) ?? NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height * 0.22 - panel.frame.height))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private init(model: AppModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    @MainActor
    private func reset(model: AppModel) {
        let view = QuickSearchView(close: { [weak self] in self?.close() })
            .environment(model)
            .foregroundStyle(Theme.text)
            .tint(Theme.text)
            .frame(width: 620, height: 420)
        contentView = NSHostingView(rootView: view)
    }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override func cancelOperation(_ sender: Any?) { close() }

}

// MARK: - Contenido de la búsqueda

struct QuickResult: Identifiable {
    var id: String { vault.url.path + entry.uuid.uuidString }
    let entry: KDBX.Entry
    let vault: Vault

    func value(_ key: String) -> String { vault.resolve(entry.string(key)) }
}

struct QuickSearchView: View {
    @Environment(AppModel.self) private var model
    var compact = false
    let close: () -> Void
    @State private var query = ""
    @State private var index = 0
    @State private var copied: String?
    @FocusState private var focused: Bool

    private var results: [QuickResult] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        if terms.isEmpty && !compact { return suggestions }
        var list: [QuickResult] = []
        for vault in model.openVaults {
            for entry in vault.root.allEntries(excluding: vault.excludedFromBrowsing) {
                if terms.isEmpty {
                    // En la ventanita solo los favoritos; en la barra de menús, todo (favoritos primero).
                    guard compact || entry.isFavorite else { continue }
                } else {
                    let haystack = [entry.title, entry.userName, entry.url, entry.tags.joined(separator: " ")].joined(separator: " ").lowercased()
                    guard terms.allSatisfy(haystack.contains) else { continue }
                }
                list.append(QuickResult(entry: entry, vault: vault))
            }
        }
        // Primero las que empiezan por lo escrito, luego por título.
        let first = terms.first ?? ""
        return Array(list.sorted { a, b in
            if terms.isEmpty, a.entry.isFavorite != b.entry.isFavorite { return a.entry.isFavorite }
            let pa = a.entry.title.lowercased().hasPrefix(first), pb = b.entry.title.lowercased().hasPrefix(first)
            if pa != pb { return pa }
            return a.entry.title.localizedStandardCompare(b.entry.title) == .orderedAscending
        }.prefix(compact ? 300 : 30))
    }

    /// Sin escribir nada: las últimas que has usado (copiado o abierto) y después los favoritos.
    private var suggestions: [QuickResult] {
        var byKey: [String: QuickResult] = [:]
        var favorites: [QuickResult] = []
        for vault in model.openVaults {
            for entry in vault.root.allEntries(excluding: vault.excludedFromBrowsing) {
                let item = QuickResult(entry: entry, vault: vault)
                byKey[AppModel.recentKey(entry.uuid, in: vault.url)] = item
                if entry.isFavorite { favorites.append(item) }
            }
        }
        let recent = AppModel.recentEntryKeys.compactMap { byKey[$0] }.prefix(8)
        let used = Set(recent.map(\.id))
        favorites = favorites.filter { !used.contains($0.id) }
            .sorted { $0.entry.title.localizedStandardCompare($1.entry.title) == .orderedAscending }
        return Array(recent) + favorites
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.openVaults.isEmpty {
                locked
            } else {
                if compact {
                    searchField
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focused ? Theme.borderStrong : Theme.border))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    list
                } else {
                    searchField
                    Rectangle().fill(Theme.border).frame(height: 1)
                    list
                    footer
                }
            }
        }
        .background(compact ? Color.clear : Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 0 : 18, style: .continuous))
        .overlay {
            if !compact { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.borderStrong.opacity(0.7)) }
        }
        .onAppear {
            focused = true
            // El panel acaba de hacerse key: se repite un instante después para que el cursor quede en el buscador.
            DispatchQueue.main.async { focused = true }
        }
    }

    private var locked: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock").font(.system(size: 22)).foregroundStyle(Theme.textTertiary)
            Text("Hush está bloqueada").font(.ui(15, .semibold))
            Text("Desbloquéala para buscar tus contraseñas.").font(.ui(13)).foregroundStyle(Theme.textSecondary)
            // Con Touch ID pide la huella aquí mismo; si no se puede, abre la ventana con la contraseña.
            Group {
                if let progress = model.unlockProgress {
                    UnlockProgressBar(progress: progress).frame(width: 220)
                } else {
                    Button {
                        Task { if await model.unlockFromMenuBar() == false { close() } }
                    } label: {
                        if model.touchIDPending {
                            Text("Pon el dedo en Touch ID")
                        } else if let url = model.lockedURL ?? Preferences.lastOpened ?? model.recents.first,
                                  model.canUseTouchID(for: url) {
                            Label("Desbloquear con Touch ID", systemImage: "touchid")
                        } else {
                            Text("Desbloquear")
                        }
                    }
                    .buttonStyle(GButtonStyle(kind: .primary, compact: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.touchIDPending || model.busy)
                }
            }
            .frame(height: 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: compact ? 14 : 16, weight: .medium)).foregroundStyle(Theme.textSecondary)
            TextField(compact ? "Buscar" : "Buscar contraseñas", text: $query)
                .textFieldStyle(.plain)
                .font(.ui(compact ? 14 : 18))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onSubmit { act(.password) }
                .onChange(of: query) { index = 0 }
                .onKeyPress(.downArrow) { index = min(index + 1, max(results.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
                .onKeyPress(keys: ["b", "t", "u"], phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    switch press.characters {
                    case "b": act(.user)
                    case "t": act(.totp)
                    default: act(.openURL)
                    }
                    return .handled
                }
        }
        // El aviso flota encima: dentro del HStack encogía el buscador al aparecer.
        .overlay(alignment: .trailing) {
            if let copied {
                Label(copied, systemImage: "checkmark.circle.fill")
                    .font(.ui(12, .medium))
                    .foregroundStyle(Theme.green)
                    .padding(.leading, 8)
                    .background(Theme.background)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, compact ? 10 : 18)
        .frame(height: compact ? 34 : 60)
    }

    private var list: some View {
        let items = results
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    if items.isEmpty {
                        Text(query.isEmpty ? (compact ? "Aún no hay entradas." : "Escribe para buscar. Aquí saldrán las que uses.") : "Nada coincide con «\(query)»")
                            .font(.ui(13))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 40)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                        if let header = sectionHeader(items, offset) {
                            HStack {
                                Text(header.title).font(.ui(12, .semibold)).foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Text("\(header.count)").font(.ui(12)).foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.top, offset == 0 ? 2 : 12)
                            .padding(.bottom, 4)
                        }
                        QuickRow(item: item, selected: offset == index, showVault: model.openVaults.count > 1, compact: compact,
                                 onCopy: { index = offset; act(.password) },
                                 onAction: { action in index = offset; act(action) })
                            .id(offset)
                            .onTapGesture { index = offset; act(.password) }
                    }
                }
                .padding(8)
            }
            .onChange(of: index) { _, value in proxy.scrollTo(value) }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↩", L("copiar"))
            hint("⌘B", L("usuario"))
            hint("⌘T", "2FA")
            hint("⌘U", L("abrir web"))
            Spacer()
            hint("esc", L("cerrar"))
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .hairline(.top)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.ui(11, .semibold)).foregroundStyle(Theme.textSecondary)
            Text(label).font(.ui(11)).foregroundStyle(Theme.textTertiary)
        }
    }

    /// En la barra de menús, títulos "Favoritos" / "Todos los elementos" / "Resultados".
    private func sectionHeader(_ items: [QuickResult], _ offset: Int) -> (title: String, count: Int)? {
        if !compact {
            // Ventana de ⇧⌘P: "Recientes" y "Favoritos" solo mientras no se escribe.
            guard query.isEmpty else { return nil }
            let recent = Set(AppModel.recentEntryKeys)
            let recents = items.prefix { recent.contains(AppModel.recentKey($0.entry.uuid, in: $0.vault.url)) }.count
            if offset == 0 && recents > 0 { return (L("Recientes"), recents) }
            if offset == recents && items.count > recents { return (L("Favoritos"), items.count - recents) }
            return nil
        }
        guard query.isEmpty else { return offset == 0 ? (L("Resultados"), items.count) : nil }
        let favorites = items.filter(\.entry.isFavorite).count
        if offset == 0 && favorites > 0 { return (L("Favoritos"), favorites) }
        if offset == favorites { return (L("Todos los elementos"), items.count - favorites) }
        return nil
    }

    enum Action { case password, user, totp, openURL }

    func act(_ action: Action) {
        let items = results
        guard items.indices.contains(index) else { return }
        let item = items[index]
        switch action {
        case .password:
            // Tarjetas y notas no tienen contraseña: se copia su dato principal.
            switch item.entry.kind {
            case .card: copy(item.value(CardField.number), L("Número copiado"))
            case .note: copy(item.entry.notes, L("Nota copiada"))
            case .login: copy(item.value(FieldKey.password), L("Contraseña copiada"))
            }
        case .user: copy(item.value(FieldKey.userName), L("Usuario copiado"))
        case .totp:
            guard let totp = TOTP.from(item.entry) else { return }
            copy(totp.code(), L("Código copiado"))
        case .openURL:
            copy(item.value(FieldKey.password), L("Contraseña copiada"))
            if let url = URL.fromUserInput(item.value(FieldKey.url)) { NSWorkspace.shared.open(url) }
        }
    }

    private func copy(_ value: String, _ message: String) {
        guard !value.isEmpty else { return }
        Clipboard.copy(value, clearAfter: Preferences.clipboardSeconds)
        model.noteActivity()
        let items = results
        if items.indices.contains(index) { AppModel.markUsed(items[index].entry.uuid, in: items[index].vault.url) }
        withAnimation(.easeOut(duration: 0.12)) { copied = message }
        DispatchQueue.main.asyncAfter(deadline: compact ? .now() + 1.2 : .now() + 0.45) {
            withAnimation(.easeOut(duration: 0.15)) { copied = nil }
            if !compact { close() }
        }
    }
}

private struct QuickRow: View {
    let item: QuickResult
    let selected: Bool
    let showVault: Bool
    var compact = false
    var onCopy: () -> Void = {}
    var onAction: (QuickSearchView.Action) -> Void = { _ in }
    @State private var hovering = false

    /// Lo mismo que se ve en la lista principal según el tipo de entrada.
    private var subtitle: String {
        switch item.entry.kind {
        case .card:
            let digits = item.value(CardField.number).filter(\.isNumber)
            return digits.count >= 4 ? "•••• " + digits.suffix(4) : L("Tarjeta")
        case .note:
            return item.entry.notes.split(separator: "\n").first.map(String.init) ?? L("Nota")
        case .login:
            let user = item.value(FieldKey.userName)
            return user.isEmpty ? L("Sin usuario") : user
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            QuickIcon(entry: item.entry, vault: item.vault)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.entry.title.isEmpty ? L("Sin título") : item.entry.title).font(.ui(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(subtitle)
                    .font(.ui(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer()
            if showVault {
                Text(item.vault.name).font(.ui(11)).foregroundStyle(Theme.textTertiary)
            }
            if TOTP.from(item.entry) != nil {
                Image(systemName: "clock").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            }
            if compact {
                IconButton(symbol: "doc.on.doc", help: L("Copiar ") + item.entry.kind.mainValueName, size: 28) { onCopy() }
                Menu {
                    if item.entry.kind == .login { Button("Copiar usuario") { onAction(.user) } }
                    Button(L("Copiar ") + item.entry.kind.mainValueName) { onAction(.password) }
                    if TOTP.from(item.entry) != nil { Button("Copiar código 2FA") { onAction(.totp) } }
                    if !item.entry.url.isEmpty { Button("Copiar contraseña y abrir web") { onAction(.openURL) } }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Text("↩").font(.ui(12, .semibold)).foregroundStyle(Theme.textTertiary).opacity(selected ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: compact ? 52 : 48)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(compact ? (selected || hovering ? Theme.hover : Theme.background) : (selected ? Theme.selected : .clear))
        )
        .overlay {
            if compact { RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.border) }
        }
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .accessibilityElement(children: compact ? .contain : .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onCopy() }
    }
}

extension EntryKind {
    /// Lo que copia ↩ en la búsqueda rápida según el tipo de entrada.
    var mainValueName: String {
        switch self {
        case .login: return L("contraseña")
        case .card: return L("número")
        case .note: return L("nota")
        }
    }
}

/// Icono para la búsqueda rápida: no depende de la base activa.
private struct QuickIcon: View {
    let entry: KDBX.Entry
    let vault: Vault

    var body: some View {
        if let data = vault.customIconData(entry.customIconUUID), let image = NSImage(data: data) {
            tile(image)
        } else if let image = FaviconStore.shared.image(for: entry.url) {
            tile(image)
        } else {
            EntryAvatar(title: entry.title, size: 30)
        }
    }

    private func tile(_ image: NSImage) -> some View {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: 19, height: 19)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
    }
}

// MARK: - Barra de menús

/// Mini-app de la barra de menús: buscar y copiar, añadir, generador, abrir Hush, ajustes y bloquear.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    /// Cierra el panel (lo pone MenuBarItem).
    var dismiss: () -> Void = {}
    @State private var tab = Tab.vault

    enum Tab { case vault, generator }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            Group {
                switch tab {
                case .vault:
                    QuickSearchView(compact: true) { dismiss() }
                case .generator:
                    ScrollView { GeneratorView(onUse: nil, showsTitle: false) }
                }
            }
            .frame(height: 400)
            Rectangle().fill(Theme.border).frame(height: 1)
            tabBar
        }
        .frame(width: 380)
        .background(Theme.backgroundSubtle)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tab == .generator ? L("Generador") : (model.vault?.name ?? "Hush")).font(.ui(17, .semibold))
                if tab == .vault, model.vault != nil {
                    Text("\(model.count(.all)) entradas").font(.ui(11)).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
            if model.phase == .unlocked {
                Menu {
                    ForEach(EntryKind.allCases, id: \.self) { kind in
                        Button { add { model.newEntry(kind) } } label: { Label(kind.label, systemImage: kind.symbol) }
                    }
                    Divider()
                    Button { add { model.requestNewGroup() } } label: { Label("Grupo", systemImage: "folder.badge.plus") }
                } label: {
                    Label("Añadir", systemImage: "plus")
                        .font(.ui(13, .semibold))
                        .foregroundStyle(Theme.onPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Capsule().fill(Theme.primary))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            } else if tab == .vault, let url = model.lockedURL, !model.openVaults.isEmpty {
                // La base que ves está bloqueada pero otra sigue abierta (el buscador enseña la abierta):
                // desde aquí se desbloquea la bloqueada, con la huella y sin abrir la ventana.
                Button {
                    Task { if await model.unlockFromMenuBar() == false { dismiss() } }
                } label: {
                    if model.busy {
                        Text("Abriendo…")
                    } else if model.touchIDPending {
                        Text("Pon el dedo…")
                    } else if model.canUseTouchID(for: url) {
                        Label(L("Desbloquear \(url.deletingPathExtension().lastPathComponent)"), systemImage: "touchid")
                    } else {
                        Text(L("Desbloquear \(url.deletingPathExtension().lastPathComponent)"))
                    }
                }
                .buttonStyle(GButtonStyle(kind: .primary, compact: true))
                .disabled(model.touchIDPending || model.busy)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            if let progress = model.unlockProgress, !model.openVaults.isEmpty {
                UnlockProgressBar(progress: progress, showsLabel: false)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(L("Contraseñas"), "key.horizontal", active: tab == .vault) { tab = .vault }
            tabButton(L("Generador"), "dice", active: tab == .generator) { tab = .generator }
            tabButton(L("Abrir Hush"), "macwindow", active: false) { dismiss(); model.showMainWindow() }
            tabButton(L("Ajustes"), "gearshape", active: false) {
                dismiss()
                NSApp.activate()
                model.openSettingsAction?()
            }
            if model.openURLs.isEmpty {
                tabButton(L("Salir"), "power", active: false) { NSApp.terminate(nil) }
            } else {
                tabButton(L("Bloquear"), "lock", active: false) { model.lockAll() }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 58)
        .background(Theme.background)
        .contextMenu { Button("Salir de Hush") { NSApp.terminate(nil) } }
    }

    private func tabButton(_ title: String, _ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { TabLabel(title: title, symbol: symbol, active: active) }
            .buttonStyle(.plain)
    }

    /// Las acciones de crear abren la ventana principal, que es donde está el editor.
    private func add(_ action: @escaping () -> Void) {
        dismiss()
        model.showMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { action() }
    }
}

private struct TabLabel: View {
    let title: String
    let symbol: String
    let active: Bool
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 15, weight: active ? .semibold : .regular))
            Text(title).font(.ui(10, active ? .semibold : .medium)).lineLimit(1)
        }
        .foregroundStyle(active ? Theme.text : (hovering ? Theme.text : Theme.textSecondary))
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
