import AppKit
import BovedaCore
import KDBXKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Selección múltiple

extension AppModel {
    var isMultiSelecting: Bool { selection.count > 1 }

    /// Seleccionadas en el orden de la lista.
    var selectedIDs: [UUID] {
        let list = visibleEntries.map(\.uuid).filter(selection.contains)
        return list.isEmpty ? Array(selection) : list
    }

    /// Clic en una fila: normal, ⌘ (añadir o quitar) o ⇧ (rango).
    func click(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            var set = selection
            if set.contains(id), set.count > 1 { set.remove(id) } else { set.insert(id) }
            keepSelection = true
            selectedEntryID = set.contains(id) ? id : set.first
            keepSelection = false
            selection = set
        } else if modifiers.contains(.shift), let anchor = selectedEntryID {
            let list = visibleEntries.map(\.uuid)
            guard let a = list.firstIndex(of: anchor), let b = list.firstIndex(of: id) else { selectedEntryID = id; return }
            keepSelection = true
            selection = Set(list[min(a, b)...max(a, b)])
            keepSelection = false
            rangeEnd = id
        } else {
            selectedEntryID = id
        }
    }

    /// ⇧↑ / ⇧↓: mueve el otro extremo del rango; la entrada de partida (la del detalle) no cambia.
    func extendSelection(_ delta: Int) {
        let list = visibleEntries.map(\.uuid)
        guard let anchor = selectedEntryID, let a = list.firstIndex(of: anchor) else { moveSelection(delta); return }
        let current = rangeEnd.flatMap { selection.contains($0) ? list.firstIndex(of: $0) : nil } ?? a
        let end = min(max(current + delta, 0), list.count - 1)
        rangeEnd = list[end]
        keepSelection = true
        selection = Set(list[min(a, end)...max(a, end)])
        keepSelection = false
    }

    func selectAllEntries() {
        let list = visibleEntries.map(\.uuid)
        guard !list.isEmpty else { return }
        keepSelection = true
        if selectedEntryID == nil || !list.contains(selectedEntryID!) { selectedEntryID = list.first }
        selection = Set(list)
        keepSelection = false
    }

    func deleteSelection() {
        let ids = selectedIDs
        // Al buscar también en la papelera se pueden mezclar: se dice qué pasa con cada parte.
        let permanent = ids.filter(deletesPermanently).count
        let moved = ids.count - permanent
        if permanent > 0 {
            let title = moved == 0 ? L("¿Eliminar \(permanent) entradas para siempre?") : L("¿Borrar \(ids.count) entradas?")
            let detail = moved == 0 ? L("No irán a la papelera.") : L("\(moved) irán a la papelera y \(permanent) se eliminarán para siempre.")
            guard confirmPermanentDelete(title, detail: detail) else { return }
        }
        mutate { vault in for id in ids { vault.deleteEntry(id) } }
        selectedEntryID = visibleEntries.first?.uuid
        showToast([moved > 0 ? L("\(moved) movidas a la papelera") : nil, permanent > 0 ? L("\(permanent) eliminadas para siempre") : nil]
            .compactMap { $0 }.joined(separator: " · "))
    }

    func moveSelection(to group: UUID) {
        let ids = selectedIDs
        mutate { vault in for id in ids { vault.moveEntry(id, to: group) } }
        showToast(L("\(ids.count) entradas movidas"))
    }

    func setFavorite(_ favorite: Bool, for ids: [UUID]) {
        mutate { vault in
            for id in ids where (vault.locate(id)?.entry.isFavorite ?? favorite) != favorite { vault.toggleFavorite(id) }
        }
    }
}

// MARK: - Copiar

extension AppModel {
    func copyUserAndPassword(_ entry: KDBX.Entry) {
        copy("\(value(FieldKey.userName, of: entry))\n\(value(FieldKey.password, of: entry))", label: L("Usuario y contraseña"), entry: entry.uuid)
    }

    /// Todos los campos como texto (sin los ocultos que no sean la contraseña).
    func copyAllFields(_ entry: KDBX.Entry) {
        var lines: [String] = [L("Título: \(entry.title)")]
        let fields: [(String, String)] = [(L("Usuario"), FieldKey.userName), (L("Contraseña"), FieldKey.password), (L("Web"), FieldKey.url)]
        for (label, key) in fields {
            let text = value(key, of: entry)
            if !text.isEmpty { lines.append("\(label): \(text)") }
        }
        for field in entry.customFields { lines.append("\(field.key): \(resolved(field.value.revealedString))") }
        if !entry.notes.isEmpty { lines.append("Notas:\n\(entry.notes)") }
        copy(lines.joined(separator: "\n"), label: L("Todos los campos"), entry: entry.uuid)
    }

    func copyPasswordAndOpenURL(_ entry: KDBX.Entry) {
        copy(value(FieldKey.password, of: entry), label: L("Contraseña"), entry: entry.uuid)
        if let url = URL.fromUserInput(value(FieldKey.url, of: entry)) { NSWorkspace.shared.open(url) }
    }

    /// Texto que, pegado en otra entrada, apunta a este campo y se actualiza solo.
    func copyReference(_ field: Character, of entry: KDBX.Entry) {
        copy(FieldReference.make(field: field, to: entry), label: L("Referencia"), markUsed: false)
    }

    /// Copia la entrada entera (con adjuntos e icono) para pegarla en otra base o grupo.
    func copyEntry(_ id: UUID) {
        guard let package = vault?.package(id) else { return }
        entryClipboard = (package, package.entry.title)
        showToast(L("Entrada copiada · pégala con ⌥⌘V en cualquier base"))
    }

    func pasteEntry() {
        guard let clip = entryClipboard, let group = targetGroupID else { return }
        var pasted: UUID?
        mutate { pasted = $0.paste(clip.package, into: group) }
        selectedEntryID = pasted
        showToast(L("«\(clip.title)» pegada"))
    }
}

// MARK: - Auditoría, historial e iconos

extension AppModel {
    func toggleAuditExclusion(_ id: UUID) {
        mutate { vault in
            vault.root.mutateEntry(id) { entry in
                entry.qualityCheck = entry.excludedFromAudit ? nil : false
                entry.times?.lastModificationTime = Date()
            }
        }
    }

    func restoreHistory(_ index: Int, of id: UUID) {
        mutate { $0.restoreHistory(index, of: id) }
        showToast(L("Versión restaurada · la de antes queda en el historial"))
    }

    func deleteHistory(_ index: Int, of id: UUID) {
        mutate { $0.deleteHistory(index, of: id) }
    }

    func pickIcon(for id: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = L("Elige una imagen para el icono")
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url),
              let png = FaviconStore.pngThumbnail(image, size: 128) else { return }
        mutate { $0.setCustomIcon(png, for: id) }
    }

    /// Guarda el logo de la web dentro de la base, así también se ve en el móvil.
    func useFaviconAsIcon(_ entry: KDBX.Entry) {
        guard let image = FaviconStore.shared.image(for: entry.url), let png = FaviconStore.pngThumbnail(image, size: 64) else {
            showToast(L("Aún no hay logo para esta web"))
            return
        }
        mutate { $0.setCustomIcon(png, for: entry.uuid) }
    }

    func removeIcon(_ id: UUID) { mutate { $0.setCustomIcon(nil, for: id) } }

    /// Descarga de golpe los logos de todas las webs de la base.
    func fetchAllFavicons() {
        guard let vault else { return }
        if !Preferences.showFavicons { Preferences.showFavicons = true }
        let count = FaviconStore.shared.prefetch(vault.root.allEntries(excluding: vault.excludedFromBrowsing).map(\.url))
        showToast(count == 0 ? L("Ya están todos los logos") : L("Descargando \(count) logos…"))
    }
}

// MARK: - Exportar

extension AppModel {
    /// Exporta a CSV (o a .zip con los adjuntos). El archivo va sin cifrar, así que se avisa antes.
    func export(only ids: Set<UUID>? = nil, withAttachments: Bool) {
        guard let vault else { return }
        let warning = NSAlert()
        warning.messageText = L("El archivo exportado no va cifrado")
        warning.informativeText = L("Cualquiera que lo abra verá tus contraseñas. Bórralo en cuanto termines de usarlo.")
        warning.alertStyle = .warning
        warning.addButton(withTitle: L("Exportar"))
        warning.addButton(withTitle: L("Cancelar"))
        guard warning.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSSavePanel()
        let base = vault.name + (ids == nil ? "" : L(" (selección)"))
        panel.nameFieldStringValue = base + (withAttachments ? ".zip" : ".csv")
        panel.allowedContentTypes = [withAttachments ? .zip : .commaSeparatedText]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let snapshot = vault
        // Puede tardar: se hace en segundo plano para que la ventana siga respondiendo.
        showToast(L("Exportando…"))
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Self.writeExport(snapshot, only: ids, csv: snapshot.csv(only: ids), base: base, to: target, withAttachments: withAttachments)
                }.value
                showToast(L("Exportado en \(target.lastPathComponent)"))
            } catch {
                alert = AlertMessage(title: L("No se ha podido exportar"), message: error.localizedDescription)
            }
        }
    }

    nonisolated private static func writeExport(_ vault: Vault, only ids: Set<UUID>?, csv: String, base: String, to target: URL, withAttachments: Bool) throws {
        do {
            if !withAttachments {
                try Data(csv.utf8).write(to: target, options: .atomic)
            } else {
                let folder = FileManager.default.temporaryDirectory.appending(path: "Boveda-export-\(UUID().uuidString)/\(base)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
                try Data(csv.utf8).write(to: folder.appending(path: "entradas.csv"))
                for entry in vault.root.allEntries(excluding: vault.excludedFromBrowsing) where ids?.contains(entry.uuid) ?? true {
                    let files = vault.attachments(of: entry)
                    guard !files.isEmpty else { continue }
                    let safe = (entry.title.isEmpty ? L("Sin título") : entry.title).replacingOccurrences(of: "/", with: "-")
                    let dir = folder.appending(path: "Adjuntos/\(safe) (\(entry.uuid.uuidString.prefix(4)))", directoryHint: .isDirectory)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    for file in files {
                        try vault.attachmentData(named: file.name, in: entry)?.write(to: dir.appending(path: (file.name as NSString).lastPathComponent))
                    }
                }
                try? FileManager.default.removeItem(at: target)
                let zip = Process()
                zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                zip.arguments = ["-c", "-k", "--keepParent", folder.path, target.path]
                try zip.run()
                zip.waitUntilExit()
                guard zip.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
            }
        }
    }
}

// MARK: - Ventana, Dock, tema e inicio de sesión

extension AppModel {
    /// Desbloqueo y bienvenida en una ventana compacta; al entrar, vuelve el tamaño que tenía la principal.
    func fitWindowToPhase(animated: Bool = true) {
        guard let window = mainWindow, !window.styleMask.contains(.fullScreen) else { return }
        let key = "unlockedWindowFrame"
        let compactSize = NSSize(width: 760, height: 520)  // Apaisada, como una hoja de desbloqueo.
        let isCompact = window.frame.width < 800
        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var target: NSRect
        if phase == .unlocked {
            guard isCompact else { return }
            let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
            target = UserDefaults.standard.string(forKey: key).map(NSRectFromString)
                ?? NSRect(x: center.x - 640, y: center.y - 390, width: 1280, height: 780)
        } else {
            guard window.frame.size != compactSize else { return }
            // Se recuerda el tamaño grande para devolverlo al desbloquear.
            if !isCompact { UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key) }
            target = NSRect(x: window.frame.midX - compactSize.width / 2, y: window.frame.midY - compactSize.height / 2,
                            width: compactSize.width, height: compactSize.height)
        }
        if let screen = window.screen ?? NSScreen.main { target = window.constrainFrameRect(target, to: screen) }
        window.setFrame(target, display: true, animate: animate)
    }

    func applyAlwaysOnTop() {
        mainWindow?.level = alwaysOnTop ? .floating : .normal
    }

    static func applyAppearance(_ mode: AppearanceMode = Preferences.appearance) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// Sin icono en el Dock la app vive en la barra de menús.
    static func applyDockIcon(hidden: Bool = Preferences.hideDockIcon) {
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
        if !hidden { NSApp.activate() }
    }

    static var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func setOpensAtLogin(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// Trae la ventana principal al frente (o la vuelve a abrir si se había cerrado).
    func showMainWindow() {
        NSApp.activate()
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindowAction?()
        }
    }
}

// MARK: - Usadas hace poco (para las sugerencias de ⇧⌘P)

extension AppModel {
    private static let recentKey = "recentEntries"

    /// Entradas copiadas o abiertas, la última primero. Solo se guardan identificadores:
    /// «ruta de la base|UUID», para no confundir una base con una copia suya (mismos UUID).
    static var recentEntryKeys: [String] { UserDefaults.standard.stringArray(forKey: recentKey) ?? [] }

    static func recentKey(_ id: UUID, in vaultURL: URL) -> String { vaultURL.path + "|" + id.uuidString }

    static func markUsed(_ id: UUID?, in vaultURL: URL?) {
        guard let id, let vaultURL else { return }
        let key = recentKey(id, in: vaultURL)
        let list = [key] + recentEntryKeys.filter { $0 != key }
        UserDefaults.standard.set(Array(list.prefix(30)), forKey: recentKey)
    }

    /// La entrada usada en la base activa.
    func markUsed(_ id: UUID?) { Self.markUsed(id, in: vault?.url) }
}

// MARK: - Cerrar la ventana sin cerrar Hush

/// SwiftUI cierra la app entera al cerrar su única ventana principal (`Window`), aunque el delegado diga
/// lo contrario. Con el icono de la barra de menús (o sin icono en el Dock), la cruz solo oculta la ventana:
/// Hush sigue abierta y vuelve desde la barra, el Dock o el atajo. Sin ellos, la cruz cierra como siempre.
@MainActor
final class WindowCloser: NSObject {
    static let shared = WindowCloser()

    func attach(to window: NSWindow?) {
        guard let button = window?.standardWindowButton(.closeButton) else { return }
        button.target = self
        button.action = #selector(closeClicked(_:))
    }

    @objc private func closeClicked(_ sender: NSButton) {
        guard let window = sender.window else { return }
        if Preferences.menuBarIcon || Preferences.hideDockIcon { window.orderOut(nil) } else { window.close() }
    }
}

