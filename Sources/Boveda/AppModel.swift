import AppKit
import BovedaCore
import KDBXKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case all, favorites, twoFactor, passkeys, attachments, expired, recycleBin
    case group(UUID)
    case tag(String)
    case audit(AuditKind)
}

enum AuditKind: Hashable { case pwned, duplicates, similar, weak, missing2FA, all }

/// Zonas que se pueden enfocar con F1, F2 y F3 como en KeePassXC.
enum FocusArea: Hashable { case groups, entries, search }

enum SortKey: String, CaseIterable {
    case title = "Título"
    case userName = "Usuario"
    case url = "URL"
    case modified = "Modificado"
    case created = "Creado"
    case passwordChanged = "Contraseña cambiada"
}

/// Dónde busca el buscador.
struct SearchOptions: Codable, Equatable {
    var title = true
    var userName = true
    var url = true
    var notes = true
    var tags = true
    var customFields = true
    var includeRecycleBin = false
    var includeHistory = false
    var showExpired = true
}

enum AppearanceMode: Int, CaseIterable {
    case system, light, dark
    var label: String { ["Como el sistema", "Claro", "Oscuro"][rawValue] }
}

/// Ajustes guardados en el Mac (no en la base de datos).
struct Preferences {
    private static let defaults = UserDefaults.standard

    static var autoLockMinutes: Int {
        get { defaults.object(forKey: "autoLockMinutes") as? Int ?? 5 }
        set { defaults.set(newValue, forKey: "autoLockMinutes") }
    }

    static var clipboardSeconds: Int {
        get { defaults.object(forKey: "clipboardSeconds") as? Int ?? 30 }
        set { defaults.set(newValue, forKey: "clipboardSeconds") }
    }

    static var touchIDEnabled: Bool {
        get { defaults.object(forKey: "touchIDEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "touchIDEnabled") }
    }

    /// Cada cuántos días hay que volver a escribir la contraseña maestra aunque haya Touch ID (0 = nunca).
    static var masterPasswordDays: Int {
        get { defaults.object(forKey: "masterPasswordDays") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "masterPasswordDays") }
    }

    /// Mostrar el logo de la web de cada entrada (se descarga directamente de la web).
    static var showFavicons: Bool {
        get { defaults.object(forKey: "showFavicons") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showFavicons") }
    }

    static var lockOnSleep: Bool {
        get { defaults.object(forKey: "lockOnSleep") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "lockOnSleep") }
    }

    static var openLastDatabase: Bool {
        get { defaults.object(forKey: "openLastDatabase") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "openLastDatabase") }
    }

    static var lastOpened: URL? {
        get { defaults.string(forKey: "lastOpened").map { URL(fileURLWithPath: $0) } }
        set { defaults.set(newValue?.path, forKey: "lastOpened") }
    }

    static var recents: [URL] {
        get { (defaults.stringArray(forKey: "recents") ?? []).map { URL(fileURLWithPath: $0) } }
        set { defaults.set(newValue.map(\.path), forKey: "recents") }
    }

    static var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.integer(forKey: "appearance")) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearance") }
    }

    /// Icono en la barra de menús con la búsqueda rápida.
    static var menuBarIcon: Bool {
        get { defaults.object(forKey: "menuBarIcon") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "menuBarIcon") }
    }

    static var hideDockIcon: Bool {
        get { defaults.object(forKey: "hideDockIcon") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "hideDockIcon") }
    }

    static var alwaysOnTop: Bool {
        get { defaults.object(forKey: "alwaysOnTop") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "alwaysOnTop") }
    }

    static var quickSearchHotkey: Int {
        get { defaults.object(forKey: "quickSearchHotkey") as? Int ?? 4 }
        set { defaults.set(newValue, forKey: "quickSearchHotkey") }
    }

    /// Comprobar filtraciones con Have I Been Pwned (solo viajan 5 caracteres de la huella).
    static var checkBreaches: Bool {
        get { defaults.object(forKey: "checkBreaches") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "checkBreaches") }
    }

    /// Avisar de webs que permiten 2FA (lista pública de 2fa.directory).
    static var check2FA: Bool {
        get { defaults.object(forKey: "check2FA") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "check2FA") }
    }

    static var searchOptions: SearchOptions {
        get {
            guard let data = defaults.data(forKey: "searchOptions"), let value = try? JSONDecoder().decode(SearchOptions.self, from: data) else { return SearchOptions() }
            return value
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "searchOptions") }
    }

    static var generator: GeneratorOptions {
        get {
            guard let data = defaults.data(forKey: "generator"), let value = try? JSONDecoder().decode(GeneratorOptions.self, from: data) else { return GeneratorOptions() }
            return value
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "generator") }
    }
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case welcome
        case locked(URL)
        case unlocked
    }

    enum SaveState: Equatable { case saved, saving, failed(String) }

    var phase: Phase = .welcome {
        didSet { MenuBarItem.shared.update() }  // Nombre del icono para VoiceOver: bloqueada o no.
    }
    private(set) var vault: Vault? {
        didSet { vaultVersion += 1 }
    }
    @ObservationIgnored private var vaultVersion = 0
    /// Última auditoría terminada (se calcula en segundo plano) y la que está en curso.
    private var auditPublished: (version: Int, url: URL, audit: Audit, passwords: [String])?
    @ObservationIgnored private var auditComputing: Int?
    /// Base a la que se acaba de cambiar (para el aviso visual de cambio).
    var switchedTo: URL?
    private var switchHUDTask: Task<Void, Never>?
    var sidebar: SidebarItem = .all
    /// Entrada principal seleccionada (la que se ve en el detalle).
    var selectedEntryID: UUID? {
        didSet { if !keepSelection { selection = selectedEntryID.map { [$0] } ?? [] } }
    }
    /// Todas las seleccionadas (con ⌘ o ⇧ se pueden elegir varias).
    var selection: Set<UUID> = []
    @ObservationIgnored var keepSelection = false
    /// Extremo móvil de un rango hecho con ⇧ (el otro es la entrada seleccionada).
    @ObservationIgnored var rangeEnd: UUID?
    var searchOptions = Preferences.searchOptions {
        didSet { Preferences.searchOptions = searchOptions }
    }
    /// Entrada copiada con "Copiar entrada" para pegarla en otra base (solo en memoria, nunca en el portapapeles).
    var entryClipboard: (package: EntryPackage, title: String)?
    var alwaysOnTop = Preferences.alwaysOnTop {
        didSet { Preferences.alwaysOnTop = alwaysOnTop; applyAlwaysOnTop() }
    }
    var menuBarIcon = Preferences.menuBarIcon || Preferences.hideDockIcon {
        didSet { Preferences.menuBarIcon = menuBarIcon; MenuBarItem.shared.update() }
    }
    @ObservationIgnored weak var mainWindow: NSWindow? {
        didSet {
            applyAlwaysOnTop()
            // Al abrir la ventana, tamaño según la pantalla (compacta si está bloqueada).
            if oldValue !== mainWindow {
                fitWindowToPhase(animated: false)
                WindowCloser.shared.attach(to: mainWindow)
            }
        }
    }
    @ObservationIgnored var openMainWindowAction: (() -> Void)?
    @ObservationIgnored var openSettingsAction: (() -> Void)?
    var search = ""
    var sortKey: SortKey = .title
    var sortAscending = true
    var saveState: SaveState = .saved
    var busy = false
    var unlockError: String?
    var alert: AlertMessage?
    var editing: EntryDraft?
    var toast: String?
    var recents: [URL] = Preferences.recents
    var searchFocusTrigger = 0
    var focusRequest: FocusArea?
    var wantsCreate = false
    var hideUsernames = false
    var revealPassword = false
    var sheet: SheetKind?
    /// Grupo donde se creará el próximo grupo nuevo (nil = raíz).
    var newGroupParent: UUID?

    enum SheetKind: String, Identifiable {
        case shortcuts, report, databaseSettings, newGroup, totp, history
        var id: String { rawValue }
    }

    private var saveTask: Task<Void, Never>?
    /// Última versión pendiente de escribir. Se guarda aunque se bloquee la base mientras tanto.
    private var pendingSnapshot: Vault?
    /// Bases desbloqueadas que no se están viendo ahora (para tener varias abiertas a la vez).
    private var sessions: [URL: Vault] = [:]
    /// Mientras se cambia la contraseña maestra no se aceptan otros cambios.
    private(set) var changingCredentials = false
    /// Referencia para que el delegado de la app espere a los guardados antes de salir.
    nonisolated(unsafe) static weak var shared: AppModel?

    /// Sube con cada cambio local; una recarga que empezó antes se descarta.
    private var revision = 0
    /// Sube al bloquear o dormir; un desbloqueo que empezó antes no llega a abrir.
    private var unlockGeneration = 0
    private var lastActivity = Date()
    private var timers: [Timer] = []
    private var toastTask: Task<Void, Never>?

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        var reload = false
    }

    init() {
        let last = Preferences.lastOpened ?? recents.first
        if Preferences.openLastDatabase, let last, FileManager.default.fileExists(atPath: last.path) {
            phase = .locked(last)
        }
        startMonitors()
        AppModel.shared = self
    }

    // MARK: Varias bases de datos

    /// Bases desbloqueadas ahora mismo (la activa y las de fondo).
    var openURLs: Set<URL> {
        var urls = Set(sessions.keys)
        if let url = vault?.url { urls.insert(url) }
        return urls
    }

    var activeURL: URL? { vault?.url ?? lockedURL }

    func isOpen(_ url: URL) -> Bool { openURLs.contains(url) }

    /// Cambia a otra base: si ya está desbloqueada se muestra al momento; si no, se pide la contraseña.
    func switchTo(_ url: URL) {
        guard url != vault?.url else { return }
        Task {
            await flushSaves()
            parkActive()
            unlockError = nil
            withAnimation(.easeOut(duration: 0.18)) {
                if let session = sessions.removeValue(forKey: url) {
                    activate(session)
                    checkDisk()
                } else {
                    phase = .locked(url)
                }
            }
            flashSwitch(to: url)
        }
    }

    /// Muestra un momento el nombre de la base a la que se ha cambiado.
    private func flashSwitch(to url: URL) {
        switchHUDTask?.cancel()
        // Con «Reducir movimiento», el aviso aparece sin escalar ni rebotar.
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduce ? .easeOut(duration: 0.15) : .spring(response: 0.25, dampingFraction: 0.85)) { switchedTo = url }
        switchHUDTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1100))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { self?.switchedTo = nil }
        }
    }

    /// Número de entradas de una base abierta (activa o en segundo plano).
    func entryCount(of url: URL) -> Int? {
        let open = vault?.url == url ? vault : sessions[url]
        guard let open else { return nil }
        return open.root.entryCount(excluding: open.excludedFromBrowsing)
    }

    /// Todas las bases desbloqueadas (la activa primero), para la búsqueda rápida y las ventanas aparte.
    var openVaults: [Vault] {
        (vault.map { [$0] } ?? []) + recents.compactMap { url in url == vault?.url ? nil : sessions[url] }
    }

    func openVault(_ url: URL) -> Vault? { vault?.url == url ? vault : sessions[url] }

    /// ⌘1…⌘9: la base número n de la lista.
    func switchTo(index: Int) {
        guard recents.indices.contains(index) else { return }
        switchTo(recents[index])
    }

    /// Guarda la base activa en segundo plano para poder volver a ella sin desbloquear.
    private func parkActive() {
        guard let current = vault else { return }
        sessions[current.url] = current
        vault = nil
        editing = nil
    }

    private func activate(_ session: Vault) {
        vault = session
        Preferences.lastOpened = session.url
        sidebar = .all
        search = ""
        saveState = unsavedURLs.contains(session.url) ? .failed("Sin guardar") : .saved
        lastActivity = Date()
        phase = .unlocked
        selectedEntryID = visibleEntries.first?.uuid
        scheduleAuditChecks()
        if Preferences.check2FA { AuditServices.shared.loadTwoFactorList() }
    }

    /// Bloquea una base abierta en segundo plano.
    func lockBackground(_ url: URL) {
        guard rescueUnsaved([url]) else { return }
        sessions.removeValue(forKey: url)
        // La base que estás viendo sigue abierta: sus adjuntos y el portapapeles se quedan. Solo se suelta
        // la entrada copiada para pegar (pudo salir de la base bloqueada) y, si ya no queda ninguna, todo.
        entryClipboard = nil
        if vault == nil && sessions.isEmpty { wipeAfterLock() }
    }

    /// Añade otra base sin cerrar las abiertas.
    func addDatabase() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "kdbx") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Elige un archivo .kdbx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !recents.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            recents.append(url)
            Preferences.recents = recents
        }
        switchTo(url)
    }

    // MARK: Abrir y bloquear

    var lockedURL: URL? {
        if case let .locked(url) = phase { return url }
        return nil
    }

    func choose(_ url: URL) {
        unlockError = nil
        phase = .locked(url)
    }

    func showWelcome() {
        unlockError = nil
        phase = .welcome
    }

    func removeRecent(_ url: URL) {
        sessions.removeValue(forKey: url)
        recents.removeAll { $0 == url }
        Preferences.recents = recents
        QuickUnlock.forget(url)
    }

    /// Añade la base a la lista sin cambiar el orden (así ⌘1…⌘9 siempre apuntan a la misma).
    private func remember(_ url: URL) {
        Preferences.lastOpened = url
        guard !recents.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        recents.append(url)
        Preferences.recents = recents
    }

    /// Hay huella guardada para esta base. No mira si el lector está listo ahora mismo (puede no estarlo
    /// un momento, p. ej. tras varios intentos fallidos): así el botón de Touch ID no desaparece.
    func canUseTouchID(for url: URL) -> Bool {
        guard Preferences.touchIDEnabled, QuickUnlock.isEnrolled(url) else { return false }
        let days = Preferences.masterPasswordDays
        if days > 0, let enrolled = QuickUnlock.enrolledDate(url), enrolled.addingTimeInterval(Double(days) * 86400) < Date() {
            return false
        }
        return true
    }

    func unlock(url: URL, password: String, keyFile: URL?) async {
        unlockError = nil
        let generation = unlockGeneration
        busy = true
        defer { busy = false }
        // Si al bloquear quedó un guardado a medias, esperamos a que termine antes de leer el archivo.
        await flushSaves()
        do {
            let keyData = try keyFile.map { try Data(contentsOf: $0) }
            let unlock: UnlockData
            if let keyData {
                unlock = password.isEmpty ? try UnlockData(keyFile: keyData) : try UnlockData(masterPassword: password, keyFile: keyData)
            } else {
                unlock = UnlockData(masterPassword: password)
            }
            let opened = try await Task.detached(priority: .userInitiated) { try Vault.open(url: url, unlock: unlock) }.value
            guard generation == unlockGeneration, lockedURL == url else { return }
            if Preferences.touchIDEnabled, QuickUnlock.isAvailable {
                try? QuickUnlock.enroll(unlock, for: url)
            }
            didOpen(opened)
        } catch {
            unlockError = error.localizedDescription
        }
    }

    /// Devuelve true si ha desbloqueado; false si se canceló o falló (entonces toca la contraseña).
    @discardableResult
    func unlockWithTouchID(url: URL) async -> Bool {
        unlockError = nil
        let generation = unlockGeneration
        do {
            let unlock = try await QuickUnlock.unlock(url, reason: "desbloquear \(url.deletingPathExtension().lastPathComponent)")
            busy = true
            defer { busy = false }
            await flushSaves()
            guard generation == unlockGeneration, lockedURL == url else { return false }
            let opened = try await Task.detached(priority: .userInitiated) { try Vault.open(url: url, unlock: unlock) }.value
            guard generation == unlockGeneration, lockedURL == url else { return false }
            didOpen(opened)
            return true
        } catch QuickUnlock.Failure.cancelled {
            // El usuario prefiere escribir la contraseña.
        } catch VaultError.wrongCredentials {
            // La contraseña maestra ha cambiado en otro dispositivo.
            QuickUnlock.forget(url)
            unlockError = "La contraseña maestra ha cambiado. Escríbela para volver a activar Touch ID."
        } catch {
            unlockError = error.localizedDescription
        }
        return false
    }

    func create(at url: URL, name: String, password: String) async {
        busy = true
        defer { busy = false }
        do {
            let unlock = UnlockData(masterPassword: password)
            let vault = try await Task.detached(priority: .userInitiated) { try Vault.create(at: url, name: name, unlock: unlock) }.value
            if Preferences.touchIDEnabled, QuickUnlock.isAvailable { try? QuickUnlock.enroll(unlock, for: url) }
            didOpen(vault)
        } catch {
            alert = AlertMessage(title: "No se ha podido crear", message: error.localizedDescription)
        }
    }

    private func didOpen(_ opened: Vault) {
        parkActive()
        sessions.removeValue(forKey: opened.url)
        remember(opened.url)
        activate(opened)
    }

    /// ⌘L: bloquea la base que se está viendo. Las demás siguen abiertas.
    /// `force`: el bloqueo automático (inactividad, reposo) bloquea aunque no se haya podido rescatar algo.
    /// Devuelve false si no se ha bloqueado (cambios sin poner a salvo): la base sigue abierta.
    @discardableResult
    func lock(force: Bool = false) -> Bool {
        guard let url = vault?.url else { unlockGeneration += 1; return true }
        guard rescueUnsaved([url]) || force else { return false }
        unlockGeneration += 1
        editing = nil
        sheet = nil
        // La clave y los datos se borran de memoria al soltar la última referencia.
        // Si queda un guardado pendiente, su copia se termina de escribir antes de soltarse.
        vault = nil
        selectedEntryID = nil
        search = ""
        wipeAfterLock()
        phase = .locked(url)
        return true
    }

    /// ⇧⌘L, inactividad o reposo: bloquea todas.
    func lockAll(force: Bool = false) {
        guard rescueUnsaved() || force else { return }
        unlockGeneration += 1
        sessions.removeAll()
        if vault != nil { lock(force: true) }
        wipeAfterLock()
    }

    /// Lo que queda de una base fuera de ella y no debe sobrevivir al bloqueo: la entrada copiada para pegar
    /// (con sus adjuntos), las contraseñas que usa la auditoría, lo que Hush dejó en el portapapeles y los
    /// adjuntos abiertos. Un cálculo de auditoría a medias se descarta al terminar.
    private func wipeAfterLock() {
        entryClipboard = nil
        auditPublished = nil
        auditComputing = nil
        Clipboard.clearIfOurs()
        AttachmentTemp.clear()
        AuditServices.shared.reset()  // Resultados de filtraciones (hashes de contraseñas) de la base cerrada.
    }

    // MARK: Lista visible

    var root: KDBX.Group? { vault?.root }

    var visibleEntries: [KDBX.Entry] {
        guard let vault else { return [] }
        let excluded = vault.excludedFromBrowsing
        var list: [KDBX.Entry]
        switch sidebar {
        case .all: list = vault.root.allEntries(excluding: excluded)
        case .favorites: list = vault.root.allEntries(excluding: excluded).filter(\.isFavorite)
        case .twoFactor: list = vault.root.allEntries(excluding: excluded).filter { TOTP.from($0) != nil }
        case .passkeys: list = vault.root.allEntries(excluding: excluded).filter(\.hasPasskey)
        case .attachments: list = vault.root.allEntries(excluding: excluded).filter(\.hasAttachments)
        case let .audit(kind):
            let ids = auditIDs(kind)
            list = vault.root.allEntries(excluding: excluded).filter { ids.contains($0.uuid) }
        case .expired: list = vault.root.allEntries(excluding: excluded).filter(\.isExpired)
        case .recycleBin: list = vault.recycleBinUUID.flatMap { vault.root.group($0) }?.allEntries() ?? []
        case let .group(id): list = vault.root.group(id)?.allEntries(excluding: excluded.subtracting([id])) ?? []
        case let .tag(tag): list = vault.root.allEntries(excluding: excluded).filter { $0.tags.contains(tag) }
        }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            // Al buscar se mira en toda la base de datos, como Strongbox.
            let options = searchOptions
            if sidebar != .recycleBin {
                list = vault.root.allEntries(excluding: options.includeRecycleBin ? [] : excluded)
            }
            if !options.showExpired { list = list.filter { !$0.isExpired } }
            let terms = query.split(separator: " ").map(String.init)
            list = list.filter { entry in
                let versions = options.includeHistory ? [entry] + entry.history : [entry]
                let haystack = versions.map { Self.searchText(of: $0, options: options) }.joined(separator: " ")
                return terms.allSatisfy { haystack.contains($0) }
            }
        }
        list.sort { a, b in
            let result: Bool
            switch sortKey {
            case .title: result = a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .userName: result = a.userName.localizedStandardCompare(b.userName) == .orderedAscending
            case .url: result = a.url.localizedStandardCompare(b.url) == .orderedAscending
            case .modified: result = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
            case .created: result = (a.times?.creationTime ?? .distantPast) < (b.times?.creationTime ?? .distantPast)
            case .passwordChanged: result = (a.passwordChangedDate ?? .distantPast) < (b.passwordChangedDate ?? .distantPast)
            }
            return sortAscending ? result : !result
        }
        return list
    }

    static func searchText(of entry: KDBX.Entry, options: SearchOptions) -> String {
        var parts: [String] = []
        if options.title { parts.append(entry.title) }
        if options.userName { parts.append(entry.userName) }
        if options.url { parts.append(entry.url) }
        if options.notes { parts.append(entry.notes) }
        if options.tags { parts += entry.tags }
        if options.customFields { parts += entry.customFields.filter { !entry.isProtected($0.key) }.map { $0.value.revealedString } }
        return parts.joined(separator: " ").lowercased()
    }

    var selectedEntry: LocatedEntry? {
        guard let id = selectedEntryID else { return nil }
        return vault?.locate(id)
    }

    func count(_ item: SidebarItem) -> Int {
        guard let vault else { return 0 }
        let excluded = vault.excludedFromBrowsing
        switch item {
        case .all: return vault.root.entryCount(excluding: excluded)
        case .favorites: return vault.root.allEntries(excluding: excluded).filter(\.isFavorite).count
        case .twoFactor: return vault.root.allEntries(excluding: excluded).filter { TOTP.from($0) != nil }.count
        case .passkeys: return vault.root.allEntries(excluding: excluded).filter(\.hasPasskey).count
        case .attachments: return vault.root.allEntries(excluding: excluded).filter(\.hasAttachments).count
        case let .audit(kind): return auditIDs(kind).count
        case .expired: return vault.root.allEntries(excluding: excluded).filter(\.isExpired).count
        case .recycleBin: return vault.recycleBinUUID.flatMap { vault.root.group($0) }?.entryCount() ?? 0
        case let .group(id): return vault.root.group(id)?.entryCount(excluding: excluded.subtracting([id])) ?? 0
        case let .tag(tag): return vault.root.allEntries(excluding: excluded).filter { $0.tags.contains(tag) }.count
        }
    }

    var sidebarTitle: String {
        switch sidebar {
        case .all: return "Todas las entradas"
        case .favorites: return "Favoritos"
        case .twoFactor: return "Códigos 2FA"
        case .passkeys: return "Claves de acceso"
        case .attachments: return "Adjuntos"
        case .audit(.pwned): return "Filtradas"
        case .audit(.duplicates): return "Contraseñas repetidas"
        case .audit(.similar): return "Contraseñas parecidas"
        case .audit(.weak): return "Contraseñas débiles"
        case .audit(.missing2FA): return "Sin 2FA"
        case .audit(.all): return "Todos los problemas"
        case .expired: return "Caducadas"
        case .recycleBin: return "Papelera"
        case let .group(id): return vault?.root.group(id)?.displayName ?? "Grupo"
        case let .tag(tag): return "#" + tag
        }
    }

    /// Auditoría de la base activa. Se recalcula en segundo plano cuando cambia la base o llegan
    /// resultados de internet; mientras tanto se muestra la última terminada, sin bloquear la ventana.
    var audit: Audit {
        let services = AuditServices.shared
        // Leer la versión hace que la vista se actualice cuando llegan resultados de filtraciones.
        let version = vaultVersion &* 100_003 &+ services.version
        guard let vault else { return Audit(entries: []) }
        let published = auditPublished
        if let published, published.version == version { return published.audit }
        if auditComputing != version {
            auditComputing = version
            let entries = auditableEntries(vault)
            let pwned = Preferences.checkBreaches ? services.pwnedSnapshot() : [:]
            let domains = Preferences.check2FA ? services.twoFactorDomains : []
            let url = vault.url
            Task { [weak self] in
                let (fresh, passwords) = await Task.detached(priority: .userInitiated) {
                    let audit = Audit(entries: entries, pwnedCount: { pwned[PwnedPasswords.sha1($0)] }, twoFactorDomains: domains)
                    let passwords = entries.filter { !$0.excludedFromAudit && $0.kind == .login }
                        .map { $0.string(FieldKey.password) }.filter { !$0.isEmpty }
                    return (audit, passwords)
                }.value
                guard let self, self.auditComputing == version else { return }
                // Si estás en una sección de auditoría, la lista cambia al llegar el resultado: la selección se ajusta.
                // (Se lee antes de limpiar `auditComputing` para no lanzar otra vez el mismo cálculo.)
                let before = self.visibleEntries
                self.auditComputing = nil
                self.auditPublished = (version, url, fresh, passwords)
                if case .audit = self.sidebar { self.reconcileSelection(previous: before) }
            }
        }
        // La de otra base no vale: mejor vacía un instante que con datos de otra.
        return published?.url == vault.url ? published!.audit : Audit(entries: [])
    }

    /// Por qué una comprobación de la base activa no es todavía fiable (nil si lo es).
    /// `pending`: aún se está comprobando; si no, ha fallado y se puede reintentar.
    func auditGap(_ kind: AuditKind) -> (text: String, pending: Bool)? {
        guard vault != nil else { return nil }
        // Hasta el primer resultado de esta base, nada puede decir «sin problemas».
        if auditFirstRunPending { return ("Comprobando…", true) }
        let services = AuditServices.shared
        var breaches: (String, Bool)?
        if Preferences.checkBreaches, kind == .pwned || kind == .all {
            let status = services.status(for: auditPublished?.passwords ?? [])
            if status.failed > 0 {
                breaches = ("No se han podido comprobar \(status.failed) contraseñas en las filtraciones. Revisa la conexión.", false)
            } else if status.pending > 0 {
                breaches = ("Comprobando filtraciones… (\(status.pending) pendientes)", true)
            }
        }
        var twoFactor: (String, Bool)?
        if Preferences.check2FA, kind == .missing2FA || kind == .all {
            switch services.twoFactorList {
            case .ready: break
            case .failed: twoFactor = ("No se ha podido descargar la lista de webs con 2FA.", false)
            case .loading, .notLoaded: twoFactor = ("Descargando la lista de webs con 2FA…", true)
            }
        }
        var similar: (String, Bool)?
        if kind == .similar || kind == .all, audit.similarSkipped {
            similar = ("Hay más de \(Audit.similarLimit) contraseñas distintas: no se buscan las parecidas.", false)
        }
        guard let gap = breaches ?? twoFactor ?? similar else { return nil }
        return (gap.0, gap.1)
    }

    /// Vuelve a intentar lo que falló (sin conexión, error del servicio…).
    func retryAuditChecks() {
        scheduleAuditChecks()
        if Preferences.check2FA, AuditServices.shared.twoFactorList != .ready { AuditServices.shared.loadTwoFactorList(fresh: true) }
    }

    /// Si aún no hay ningún resultado de la base activa (el primero se está calculando).
    var auditFirstRunPending: Bool { _ = audit; return auditPublished?.url != vault?.url }

    /// Entradas para la auditoría con las referencias ({REF:…}) de la contraseña ya resueltas,
    /// para auditar la misma contraseña que se ve en el detalle.
    func auditableEntries(_ vault: Vault) -> [KDBX.Entry] {
        vault.root.allEntries(excluding: vault.excludedFromBrowsing).map { entry in
            let raw = entry.string(FieldKey.password)
            guard FieldReference.contains(raw) else { return entry }
            var resolved = entry
            resolved.set(FieldKey.password, vault.resolve(raw))
            return resolved
        }
    }

    /// Fuerza a recalcular la auditoría (por ejemplo, al cambiar sus ajustes).
    func invalidateAudit() {
        auditComputing = nil
        vaultVersion += 1
        AuditServices.shared.touch()
    }

    private func auditIDs(_ kind: AuditKind) -> Set<UUID> {
        switch kind {
        case .pwned: return Set(audit.pwned.keys)
        case .duplicates: return Set(audit.duplicates.keys)
        case .similar: return Set(audit.similar.keys)
        case .weak: return audit.allWeak
        case .missing2FA: return audit.missing2FA
        case .all: return audit.all
        }
    }

    /// Lanza en segundo plano las comprobaciones de filtraciones de la base activa.
    func scheduleAuditChecks() {
        guard Preferences.checkBreaches, let vault else { return }
        let passwords = auditableEntries(vault)
            .filter { !$0.excludedFromAudit && $0.kind == .login }
            .map { $0.string(FieldKey.password) }.filter { !$0.isEmpty }
        AuditServices.shared.checkBreaches(passwords)
    }

    /// Grupo donde se crean las entradas nuevas según lo que esté seleccionado.
    var targetGroupID: UUID? {
        if case let .group(id) = sidebar, id != vault?.recycleBinUUID { return id }
        return vault?.root.uuid
    }

    func moveSelection(_ delta: Int) {
        let list = visibleEntries
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.uuid == selectedEntryID } ?? (delta > 0 ? -1 : list.count)
        selectedEntryID = list[min(max(index + delta, 0), list.count - 1)].uuid
    }

    // MARK: Cambios y guardado automático

    func mutate(_ body: (inout Vault) -> Void) {
        guard !changingCredentials else {
            showToast("Espera a que termine el cambio de contraseña")
            return
        }
        guard var current = vault else { return }
        let before = visibleEntries
        body(&current)
        vault = current
        revision += 1
        reconcileSelection(previous: before)
        save()
        scheduleAuditChecks()
    }

    /// Tras un cambio, la sección y la entrada seleccionadas tienen que seguir existiendo y verse
    /// (p. ej. al quitar un favorito desde Favoritos o mover una entrada a otro grupo).
    func reconcileSelection(previous: [KDBX.Entry]) {
        guard let vault else { return }
        switch sidebar {
        case let .group(id) where vault.root.group(id) == nil:
            sidebar = .all
        case let .tag(tag) where !vault.allTags.contains(tag):
            sidebar = .all
        default: break
        }
        let visible = visibleEntries
        let ids = Set(visible.map(\.uuid))
        if selection.count > 1 {
            let kept = selection.intersection(ids)
            if kept.count != selection.count {
                keepSelection = true
                selection = kept
                if let id = selectedEntryID, !kept.contains(id) { selectedEntryID = kept.first }
                keepSelection = false
            }
        }
        guard let id = selectedEntryID, !ids.contains(id) else { return }
        // La siguiente en la misma posición, como al borrar.
        let index = previous.firstIndex { $0.uuid == id } ?? 0
        selectedEntryID = visible.isEmpty ? nil : visible[min(index, visible.count - 1)].uuid
    }

    /// Guarda en segundo plano (cifrar con la clave maestra tarda) para que la app no se quede pillada.
    /// Si llegan más cambios mientras guarda, hace otra pasada al terminar con el estado más reciente.
    func save() {
        guard let current = vault else { return }
        saveState = .saving
        pendingSnapshot = current
        if saveTask == nil {
            saveTask = Task { [weak self] in await self?.runSaves() }
        }
    }

    /// Espera a que se escriba todo lo pendiente (antes de bloquear, cambiar de base o salir).
    func flushSaves() async {
        while let task = saveTask { await task.value }
    }

    var hasPendingSaves: Bool { saveTask != nil || pendingSnapshot != nil }

    /// Bases cuyo último guardado falló: lo que hay en memoria no está en su archivo.
    private(set) var unsavedURLs: Set<URL> = []

    /// Antes de soltar de memoria una base con cambios sin guardar (bloquear, cerrar o salir),
    /// los escribe en una copia cifrada aparte, comprueba que se abre y avisa de dónde está.
    /// `extra`: copias que ya no están en memoria (un guardado que falló después de bloquear).
    /// Devuelve false si algo no se ha podido poner a salvo: quien llama decide si sigue.
    @discardableResult
    func rescueUnsaved(_ urls: Set<URL>? = nil, extra: [Vault] = [], modal: Bool = false) -> Bool {
        var targets = extra
        for url in (urls ?? unsavedURLs).intersection(unsavedURLs) {
            if let latest = vault?.url == url ? vault : sessions[url] { targets.append(latest) }
        }
        guard !targets.isEmpty else { return true }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Boveda/Sin guardar", isDirectory: true)
        var written: [String] = [], failed: [String] = []
        for latest in targets {
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
            // El sufijo evita que dos bases con el mismo nombre se pisen la copia.
            let unique = UUID().uuidString.prefix(8)
            let target = folder.appendingPathComponent("\(latest.url.deletingPathExtension().lastPathComponent) sin guardar \(stamp) \(unique).kdbx")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try latest.serialized().write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                _ = try Vault.open(url: target, unlock: latest.unlock)  // Solo cuenta si se puede volver a abrir.
                unsavedURLs.remove(latest.url)
                written.append(target.path)
            } catch {
                failed.append("\(latest.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let title: String, message: String
        if failed.isEmpty {
            title = "Tus últimos cambios están en una copia aparte"
            message = "No se pudieron escribir en el archivo original. Están cifrados con la misma contraseña en:\n\n" + written.joined(separator: "\n") + "\n\nÁbrela con «Abrir base de datos…» para recuperarlos."
        } else {
            title = "No se han podido poner a salvo tus últimos cambios"
            message = (written.isEmpty ? "" : "Guardados aparte:\n" + written.joined(separator: "\n") + "\n\n") + "Sin guardar:\n" + failed.joined(separator: "\n") + "\n\nUsa «Guardar una copia como…» (⇧⌘S) antes de bloquear o salir."
        }
        if modal {
            // Al salir no queda ventana donde enseñar el aviso: se muestra antes de cerrar.
            let panel = NSAlert()
            panel.messageText = title
            panel.informativeText = message
            panel.runModal()
        } else {
            alert = AlertMessage(title: title, message: message)
        }
        return failed.isEmpty
    }

    /// Si el guardado falla cuando la base ya se ha bloqueado, lo último que había se rescata igual.
    /// Devuelve true si la base ya no estaba en memoria y se ha intentado el rescate (que ya avisa él).
    private func rescueIfGone(_ latest: Vault) -> Bool {
        guard vault?.url != latest.url, sessions[latest.url] == nil else { return false }
        rescueUnsaved(extra: [latest])
        return true
    }

    private func runSaves() async {
        defer { saveTask = nil }
        while let snapshot = pendingSnapshot {
            pendingSnapshot = nil
            do {
                let fingerprint = try await Task.detached(priority: .userInitiated) { () throws -> Data in
                    var copy = snapshot
                    try copy.save()
                    return copy.diskFingerprint
                }.value
                // El disco ya tiene lo que acabamos de escribir: lo anotamos en todas las copias vivas de esa base.
                unsavedURLs.remove(snapshot.url)
                if vault?.url == snapshot.url { vault?.adoptSavedFingerprint(fingerprint) }
                if pendingSnapshot?.url == snapshot.url { pendingSnapshot?.adoptSavedFingerprint(fingerprint) }
                sessions[snapshot.url]?.adoptSavedFingerprint(fingerprint)
            } catch VaultError.changedOnDisk {
                let latest = pendingSnapshot?.url == snapshot.url ? pendingSnapshot! : snapshot
                pendingSnapshot = nil
                unsavedURLs.insert(snapshot.url)
                // Con la base ya bloqueada, el aviso útil es el del rescate (dónde está la copia), no «Recargar».
                if rescueIfGone(latest) { return }
                saveState = .failed("Cambiado en otro dispositivo")
                alert = AlertMessage(title: "El archivo ha cambiado", message: VaultError.changedOnDisk.localizedDescription + "\n\nAl recargar se pierden los últimos cambios que has hecho aquí; tendrás que repetirlos.", reload: true)
                return
            } catch {
                let latest = pendingSnapshot?.url == snapshot.url ? pendingSnapshot! : snapshot
                pendingSnapshot = nil
                unsavedURLs.insert(snapshot.url)
                if rescueIfGone(latest) { return }
                saveState = .failed(error.localizedDescription)
                alert = AlertMessage(title: "No se ha guardado", message: error.localizedDescription)
                return
            }
        }
        saveState = .saved
    }

    /// Vuelve a leer el archivo del disco con la misma clave (por ejemplo, tras sincronizar desde el móvil).
    func reloadFromDisk() async {
        guard let current = vault else { return }
        let url = current.url, unlock = current.unlock
        let startRevision = revision
        do {
            let fresh = try await Task.detached(priority: .userInitiated) { try Vault.open(url: url, unlock: unlock) }.value
            // Si mientras tanto hubo cambios aquí o se abrió el editor, no los pisamos.
            guard vault?.url == url, revision == startRevision, editing == nil else { return }
            vault = fresh
            unsavedURLs.remove(url)  // Recargar descarta a propósito lo que no se pudo guardar.
            saveState = .saved
            if let id = selectedEntryID, fresh.locate(id) == nil { selectedEntryID = nil }
            showToast("Actualizado con los cambios de otro dispositivo")
        } catch VaultError.wrongCredentials {
            lock()
            unlockError = "La contraseña maestra ha cambiado en otro dispositivo."
            QuickUnlock.forget(url)
        } catch {
            alert = AlertMessage(title: "No se ha podido recargar", message: error.localizedDescription)
        }
    }

    // MARK: Acciones de entrada

    /// `entry`: de qué entrada sale (para «usadas hace poco»); si no se indica, la seleccionada.
    /// `markUsed: false` para lo que no es de una entrada, como el generador.
    func copy(_ value: String, label: String, entry: UUID? = nil, markUsed: Bool = true) {
        guard !value.isEmpty else { return }
        Clipboard.copy(value, clearAfter: Preferences.clipboardSeconds)
        if markUsed { self.markUsed(entry ?? selectedEntryID) }
        let suffix = Preferences.clipboardSeconds > 0 ? " · se borra en \(Preferences.clipboardSeconds) s" : ""
        showToast("Copiado: \(label)\(suffix)")
    }

    /// Valor de un campo con las referencias ({REF:…}) ya resueltas.
    func value(_ key: String, of entry: KDBX.Entry) -> String {
        let raw = entry.string(key)
        return vault?.resolve(raw) ?? raw
    }

    func resolved(_ text: String) -> String { vault?.resolve(text) ?? text }

    /// ⌘C: el dato principal según el tipo (contraseña, número de tarjeta o nota), como la búsqueda rápida.
    func copyPassword() {
        guard let entry = selectedEntry?.entry else { return }
        switch entry.kind {
        case .login: copy(value(FieldKey.password, of: entry), label: "Contraseña")
        case .card: copy(value(CardField.number, of: entry), label: "Número")
        case .note: copy(entry.notes, label: "Nota")
        }
    }

    func copyUserName() {
        guard let entry = selectedEntry?.entry else { return }
        copy(value(FieldKey.userName, of: entry), label: "Usuario")
    }

    func copyTOTP() {
        guard let entry = selectedEntry?.entry, let totp = TOTP.from(entry) else { return }
        copy(totp.code(), label: "Código 2FA")
    }

    func openURL() {
        guard let entry = selectedEntry?.entry, let url = URL.fromUserInput(value(FieldKey.url, of: entry)) else { return }
        markUsed(entry.uuid)
        NSWorkspace.shared.open(url)
    }

    func newEntry(_ kind: EntryKind = .login) {
        guard let group = targetGroupID else { return }
        var entry = KDBX.Entry.make(title: "")
        entry.setKind(kind)
        var draft = EntryDraft(entry: entry, groupID: group, isNew: true)
        if kind == .login { draft.password = PasswordGenerator.generate(Preferences.generator) }
        editing = draft
    }

    func edit(_ id: UUID) {
        guard let located = vault?.locate(id) else { return }
        editing = EntryDraft(entry: located.entry, groupID: located.group.uuid, isNew: false)
    }

    func commit(_ draft: EntryDraft) {
        mutate { vault in
            if draft.isNew {
                vault.addEntry(draft.apply(to: draft.original), to: draft.groupID)
            } else {
                vault.updateEntry(draft.original.uuid) { entry in entry = draft.apply(to: entry) }
                vault.moveEntry(draft.original.uuid, to: draft.groupID)
            }
        }
        if !visibleEntries.contains(where: { $0.uuid == draft.original.uuid }) {
            sidebar = .all
            search = ""
        }
        selectedEntryID = draft.original.uuid
        editing = nil
    }

    func duplicate(_ id: UUID) {
        guard let located = vault?.locate(id) else { return }
        var copy = located.entry
        copy.uuid = UUID()
        copy.history = []
        copy.set(FieldKey.title, located.entry.title + " (copia)")
        let now = Date()
        copy.times = KDBX.Times(creationTime: now, lastModificationTime: now, lastAccessTime: now, expires: located.entry.times?.expires, usageCount: 0, locationChanged: now)
        mutate { $0.addEntry(copy, to: located.group.uuid) }
        selectedEntryID = copy.uuid
    }

    func delete(_ id: UUID) {
        if deletesPermanently(id) {
            let title = root?.allEntries().first { $0.uuid == id }?.title ?? ""
            guard confirmPermanentDelete("¿Eliminar «\(title)» para siempre?", detail: "La entrada no irá a la papelera.") else { return }
        }
        let list = visibleEntries
        let index = list.firstIndex { $0.uuid == id }
        mutate { $0.deleteEntry(id) }
        let remaining = visibleEntries
        if let index, !remaining.isEmpty { selectedEntryID = remaining[min(index, remaining.count - 1)].uuid } else { selectedEntryID = nil }
    }

    func toggleFavorite(_ id: UUID) { mutate { $0.toggleFavorite(id) } }

    func move(_ id: UUID, to group: UUID) { mutate { $0.moveEntry(id, to: group) } }

    func addGroup(named name: String, in parent: UUID?) {
        guard let parent = parent ?? vault?.root.uuid else { return }
        var created: UUID?
        mutate { created = $0.addGroup(named: name, to: parent) }
        if let created { sidebar = .group(created) }
    }

    func renameGroup(_ id: UUID, to name: String) { mutate { $0.renameGroup(id, to: name) } }

    func deleteGroup(_ id: UUID) {
        if groupDeletesPermanently(id) {
            let name = root?.group(id)?.displayName ?? ""
            guard confirmPermanentDelete("¿Eliminar el grupo «\(name)» para siempre?", detail: "El grupo y todo lo que contiene no irán a la papelera.") else { return }
        }
        if sidebar == .group(id) { sidebar = .all }
        mutate { $0.deleteGroup(id) }
    }

    func emptyRecycleBin() { mutate { $0.emptyRecycleBin() } }

    /// Vaciar la papelera no se puede deshacer: se pide confirmación antes.
    func confirmEmptyRecycleBin() {
        guard confirmPermanentDelete("¿Vaciar la papelera?", detail: "Las entradas de la papelera se eliminarán para siempre.") else { return }
        emptyRecycleBin()
    }

    func confirmPermanentDelete(_ title: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail + " No se puede deshacer."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Eliminar para siempre")
        alert.addButton(withTitle: "Cancelar")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Saca de la papelera una entrada o un grupo y lo devuelve a donde estaba.
    func restore(_ id: UUID) {
        mutate { $0.restoreFromRecycleBin(id) }
        showToast("Restaurado")
    }

    func isGroupInRecycleBin(_ id: UUID) -> Bool { vault?.isGroupInRecycleBin(id) ?? false }

    /// Texto del botón de borrar según lo que va a pasar de verdad.
    func deleteTitle(for ids: [UUID]) -> String {
        let permanent = ids.filter(deletesPermanently).count
        if ids.isEmpty || permanent == 0 { return "Mover a la papelera" }
        return permanent == ids.count ? "Eliminar para siempre…" : "Borrar (\(ids.count - permanent) a la papelera, \(permanent) para siempre)…"
    }

    /// Si borrar elimina del todo (ya está en la papelera o la base no usa papelera).
    func deletesPermanently(_ id: UUID) -> Bool { isInRecycleBin(id) || !(vault?.usesRecycleBin ?? true) }

    func groupDeletesPermanently(_ id: UUID) -> Bool {
        guard let vault else { return false }
        let insideBin = vault.recycleBinUUID.flatMap { vault.root.group($0)?.group(id) } != nil
        return insideBin || !vault.usesRecycleBin
    }

    func isInRecycleBin(_ id: UUID) -> Bool { vault?.isInRecycleBin(id) ?? false }

    // MARK: Adjuntos

    /// Límite por archivo: todo el .kdbx se cifra y se carga en memoria, así que los adjuntos grandes lo hacen lento.
    static let attachmentLimit = 20 * 1024 * 1024

    func addAttachments(_ urls: [URL], to entryID: UUID) {
        var accepted: [URL] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            if let size = values?.fileSize, size > Self.attachmentLimit {
                alert = AlertMessage(title: "Archivo demasiado grande", message: "\(url.lastPathComponent) ocupa más de 20 MB. Los adjuntos grandes hacen que la base tarde mucho en abrir y guardar.")
                continue
            }
            accepted.append(url)
        }
        guard !accepted.isEmpty else { return }
        // Leer archivos grandes no debe congelar la ventana.
        let targetVault = vault?.url, generation = unlockGeneration
        Task {
            let added = await Task.detached(priority: .userInitiated) {
                accepted.compactMap { url in (try? Data(contentsOf: url)).map { (url.lastPathComponent, $0) } }
            }.value
            // Si mientras tanto se cambió de base o se bloqueó, no se toca otra base con el mismo UUID.
            guard !added.isEmpty, vault?.url == targetVault, unlockGeneration == generation,
                  vault?.root.allEntries().contains(where: { $0.uuid == entryID }) == true else { return }
            mutate { vault in for (name, data) in added { vault.addAttachment(named: name, data: data, to: entryID) } }
            showToast(added.count == 1 ? "Adjunto añadido" : "\(added.count) adjuntos añadidos")
        }
    }

    func pickAttachments(for entryID: UUID) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Elige los archivos que quieres adjuntar"
        guard panel.runModal() == .OK else { return }
        addAttachments(panel.urls, to: entryID)
    }

    func removeAttachment(_ name: String, from entryID: UUID) {
        mutate { $0.removeAttachment(named: name, from: entryID) }
    }

    func renameAttachment(_ name: String, to newName: String, in entryID: UUID) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutate { $0.renameAttachment(name, to: trimmed, in: entryID) }
    }

    func exportAttachment(_ name: String, of entryID: UUID) {
        guard let vault, let entry = vault.locate(entryID)?.entry, let data = vault.attachmentData(named: name, in: entry) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch {
            alert = AlertMessage(title: "No se ha podido guardar", message: error.localizedDescription)
        }
    }

    /// Abre el adjunto con su app. Se copia descifrado a una carpeta privada que se vacía al bloquear y al salir.
    func openAttachment(_ name: String, of entryID: UUID) {
        guard let vault, let entry = vault.locate(entryID)?.entry, let data = vault.attachmentData(named: name, in: entry) else { return }
        do {
            let folder = AttachmentTemp.folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appending(path: (name as NSString).lastPathComponent)
            try data.write(to: file, options: .atomic)
            NSWorkspace.shared.open(file)
        } catch {
            alert = AlertMessage(title: "No se ha podido abrir", message: error.localizedDescription)
        }
    }

    // MARK: Paneles de archivo

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "kdbx") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Elige tu archivo .kdbx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !recents.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            recents.append(url)
            Preferences.recents = recents
        }
        switchTo(url)
    }

    func saveCopyPanel() {
        guard let vault else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "kdbx") ?? .data]
        panel.nameFieldStringValue = vault.url.deletingPathExtension().lastPathComponent + " (copia).kdbx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL != vault.url.standardizedFileURL else {
            alert = AlertMessage(title: "Elige otro nombre", message: "La copia no puede reemplazar la base de datos abierta.")
            return
        }
        Task { await saveCopy(to: url) }
    }

    // MARK: Más acciones (atajos de KeePassXC)

    func copyURL() {
        guard let entry = selectedEntry?.entry else { return }
        copy(value(FieldKey.url, of: entry), label: "Web")
    }

    /// ⌘Y: contraseña seguida del código 2FA, como KeePassXC.
    func copyPasswordAndTOTP() {
        guard let entry = selectedEntry?.entry else { return }
        guard let totp = TOTP.from(entry) else { copyPassword(); return }
        copy(value(FieldKey.password, of: entry) + totp.code(), label: "Contraseña y 2FA")
    }

    func showTOTP() {
        guard let entry = selectedEntry?.entry, TOTP.from(entry) != nil else { return }
        sheet = .totp
    }

    /// ⌘⇧J: salta al grupo de la entrada seleccionada (útil tras buscar).
    func jumpToGroup() {
        guard let located = selectedEntry else { return }
        let id = located.entry.uuid
        search = ""
        sidebar = located.group.uuid == vault?.root.uuid ? .all : .group(located.group.uuid)
        selectedEntryID = id
    }

    func sortGroups(ascending: Bool) { mutate { $0.sortGroups(ascending: ascending) } }

    func requestNewGroup(in parent: UUID? = nil) {
        if let parent { newGroupParent = parent } else if case let .group(id) = sidebar, id != vault?.recycleBinUUID { newGroupParent = id } else { newGroupParent = nil }
        sheet = .newGroup
    }

    func deleteSelected() {
        if selection.count > 1 { deleteSelection(); return }
        if let id = selectedEntryID { delete(id) }
    }

    /// ⌘W: cierra la base de datos y vuelve a la pantalla de inicio.
    /// Devuelve false si la base no se ha podido cerrar (sigue abierta para poder guardar una copia).
    @discardableResult
    func closeDatabase() -> Bool {
        guard phase == .unlocked else { return true }
        guard lock() else { return false }
        if let other = sessions.keys.first { switchTo(other) } else { showWelcome() }
        return true
    }

    /// ⌘⇧S: guarda una copia cifrada con la misma contraseña en otro sitio.
    func saveCopy(to url: URL) async {
        guard let snapshot = vault else { return }
        do {
            try await Task.detached(priority: .userInitiated) {
                let bytes = try snapshot.serialized()
                try bytes.write(to: url, options: [.atomic])
            }.value
            showToast("Copia guardada en \(url.lastPathComponent)")
        } catch {
            alert = AlertMessage(title: "No se ha podido guardar la copia", message: error.localizedDescription)
        }
    }

    func updateDatabase(name: String, description: String, recycleBin: Bool, historyLimit: Int?) {
        mutate { vault in
            vault.content.database.meta.databaseName = name
            vault.content.database.meta.databaseDescription = description
            vault.content.database.meta.recycleBinEnabled = recycleBin
            vault.content.database.meta.historyMaxItems = historyLimit.map { .value(UInt32($0)) } ?? .unlimited
        }
    }

    /// Cambia la contraseña maestra. Solo se aplica si el guardado con la clave nueva sale bien.
    func changeMasterPassword(to password: String) async -> Bool {
        changingCredentials = true
        defer { changingCredentials = false }
        await flushSaves()
        guard var draft = vault else { return false }
        let newUnlock = UnlockData(masterPassword: password)
        draft.changeCredentials(newUnlock)
        busy = true
        defer { busy = false }
        do {
            let saved = try await Task.detached(priority: .userInitiated) { () throws -> Vault in
                var copy = draft
                try copy.save()
                return copy
            }.value
            guard vault?.url == saved.url else { return false }
            vault = saved
            revision += 1
            saveState = .saved
            if Preferences.touchIDEnabled, QuickUnlock.isAvailable { try? QuickUnlock.enroll(newUnlock, for: saved.url) }
            showToast("Contraseña maestra cambiada")
            return true
        } catch {
            alert = AlertMessage(title: "No se ha cambiado la contraseña", message: error.localizedDescription)
            return false
        }
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { self?.toast = nil }
        }
    }

    // MARK: Bloqueo automático y cambios externos

    func noteActivity() { lastActivity = Date() }

    private func startMonitors() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]) { [weak self] event in
            self?.lastActivity = Date()
            return event
        }
        let lockNow: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, Preferences.lockOnSleep else { return }
                // También cancela un desbloqueo que estuviera en marcha.
                self.lockAll(force: true)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lockNow)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: lockNow)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: lockNow)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkDisk() }
        }

        let tick = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.openURLs.isEmpty else { return }
                let minutes = Preferences.autoLockMinutes
                // Inactividad = no estás usando el Mac (teclado o ratón en cualquier app), no solo Hush:
                // si trabajas en otra app, Hush no se bloquea; si te vas del ordenador, sí.
                let anyInput = CGEventType(rawValue: ~0)!
                let macIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
                let idle = min(Date().timeIntervalSince(self.lastActivity), macIdle)
                if minutes > 0, idle > Double(minutes) * 60 {
                    self.lockAll(force: true)
                    return
                }
                self.checkDisk()
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        timers.append(tick)
    }

    private func checkDisk() {
        guard phase == .unlocked, editing == nil, !busy, saveTask == nil, saveState != .saving, let vault, vault.changedOnDisk() else { return }
        if case .failed = saveState { return }
        Task { await reloadFromDisk() }
    }
}

extension URL {
    static func fromUserInput(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return URL(string: trimmed) }
        return URL(string: "https://" + trimmed)
    }
}

/// Carpeta privada donde se dejan los adjuntos abiertos mientras la base está desbloqueada.
enum AttachmentTemp {
    static let folder = FileManager.default.temporaryDirectory.appending(path: "Boveda-adjuntos", directoryHint: .isDirectory)

    static func clear() {
        try? FileManager.default.removeItem(at: folder)
    }
}
