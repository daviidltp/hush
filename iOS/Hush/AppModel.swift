import BovedaCore
import KDBXKit
import LocalAuthentication
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

let log = Logger(subsystem: "com.david.hush", category: "app")

/// Estado de la app: qué bases hay, cuál está abierta y todo lo que se hace con ella.
/// Las reglas de seguridad son las del Mac: nunca guardar sin comprobar que el archivo reabre,
/// copia antes de guardar, no pisar el archivo si cambió fuera y bloquear al salir de la app.
@MainActor
@Observable
final class AppModel {
    // MARK: Bases

    private(set) var databases: [SavedDatabase] = Preferences.databases
    var selectedID: UUID? = Preferences.lastDatabase

    var selected: SavedDatabase? { databases.first { $0.id == selectedID } ?? databases.first }

    // MARK: Base abierta

    private(set) var vault: Vault?
    /// Sube con cada cambio, para que las vistas se refresquen y la auditoría se recalcule.
    private(set) var version = 0
    private(set) var openDatabase: SavedDatabase?
    @ObservationIgnored private var accessedURL: URL?

    // MARK: Desbloqueo

    var busy = false
    var unlockError: String?
    /// Progreso de abrir: se mueve hasta el 99 % en lo que tardó la última vez y llega al 100 % al abrir.
    var unlockProgress: (start: Date, expected: Double, done: Bool)?
    /// Tras bloquear a mano no se pide Face ID solo; al volver a la app, sí.
    var autoFaceID = true

    // MARK: Avisos

    var toast: Toast?
    var alert: AlertMessage?
    /// Hay cambios en memoria que no se han podido guardar en el archivo.
    private(set) var unsaved = false
    private(set) var saving = false
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var clipboardChange: Int?
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var iconCache: [UUID: UIImage] = [:]

    // MARK: Ajustes

    var autoLockSeconds = Preferences.autoLockSeconds { didSet { Preferences.autoLockSeconds = autoLockSeconds } }
    var clipboardSeconds = Preferences.clipboardSeconds { didSet { Preferences.clipboardSeconds = clipboardSeconds } }
    var faceIDEnabled = Preferences.faceIDEnabled {
        didSet {
            Preferences.faceIDEnabled = faceIDEnabled
            if !faceIDEnabled { databases.forEach { QuickUnlock.forget(key: $0.quickUnlockKey) } }
        }
    }
    var checkBreaches = Preferences.checkBreaches {
        didSet { Preferences.checkBreaches = checkBreaches; if checkBreaches { Task { await checkPwned() } } else { pwned = [:]; version += 1 } }
    }

    // MARK: Auditoría

    private(set) var audit: Audit?
    private(set) var auditVersion = -1
    private(set) var pwnedChecking = false
    @ObservationIgnored private var pwned: [String: Int] = [:]

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        var reload = false
    }

    init() {
        if selectedID == nil { selectedID = databases.first?.id }
    }

    // MARK: - Añadir y quitar bases

    /// Recuerda un archivo elegido en el selector de documentos y lo deja listo para desbloquear.
    func add(_ url: URL) {
        do {
            let bookmark = try Bookmarks.make(for: url)
            let name = url.deletingPathExtension().lastPathComponent
            if let existing = databases.firstIndex(where: { $0.name == name && $0.location == Bookmarks.locationName(url) }) {
                databases[existing].bookmark = bookmark
                select(databases[existing].id)
            } else {
                let db = SavedDatabase(name: name, location: Bookmarks.locationName(url), bookmark: bookmark)
                databases.append(db)
                select(db.id)
            }
            persist()
        } catch {
            alert = AlertMessage(title: "No se ha podido añadir", message: error.localizedDescription)
        }
    }

    /// Crea una base nueva en la carpeta de Hush (se ve en Archivos → En mi iPhone → Hush).
    func create(name: String, password: String) async {
        busy = true
        defer { busy = false }
        let clean = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Contraseñas" : name.trimmingCharacters(in: .whitespaces)
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var url = folder.appendingPathComponent(clean + ".kdbx")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(clean) \(n).kdbx"); n += 1 }
        do {
            let unlock = UnlockData(masterPassword: password)
            let target = url
            let created = try await Task.detached(priority: .userInitiated) { try Vault.create(at: target, name: clean, unlock: unlock) }.value
            add(url)
            guard var db = selected else { return }
            if faceIDEnabled, QuickUnlock.isAvailable { try? QuickUnlock.enroll(unlock, key: db.quickUnlockKey) }
            db.unlockSeconds = 1
            update(db)
            didOpen(created, db: db, url: url)
        } catch {
            alert = AlertMessage(title: "No se ha podido crear", message: error.localizedDescription)
        }
    }

    func select(_ id: UUID) {
        selectedID = id
        Preferences.lastDatabase = id
        unlockError = nil
    }

    func remove(_ db: SavedDatabase) {
        QuickUnlock.forget(key: db.quickUnlockKey)
        databases.removeAll { $0.id == db.id }
        if selectedID == db.id { selectedID = databases.first?.id }
        persist()
    }

    func setKeyFile(_ url: URL?, for db: SavedDatabase) {
        var copy = db
        if let url {
            guard let bookmark = try? Bookmarks.make(for: url) else { return }
            copy.keyFileBookmark = bookmark
            copy.keyFileName = url.lastPathComponent
        } else {
            copy.keyFileBookmark = nil
            copy.keyFileName = nil
        }
        update(copy)
    }

    private func update(_ db: SavedDatabase) {
        guard let index = databases.firstIndex(where: { $0.id == db.id }) else { return }
        databases[index] = db
        persist()
    }

    private func persist() { Preferences.databases = databases }

    // MARK: - Desbloquear

    func canUseFaceID(_ db: SavedDatabase) -> Bool {
        faceIDEnabled && QuickUnlock.isEnrolled(key: db.quickUnlockKey)
    }

    var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType == .touchID ? "Touch ID" : "Face ID"
    }

    var biometrySymbol: String { biometryName == "Touch ID" ? "touchid" : "faceid" }

    func unlock(_ db: SavedDatabase, password: String) async {
        unlockError = nil
        do {
            let keyData = try readKeyFile(db)
            let unlock: UnlockData
            if let keyData {
                unlock = password.isEmpty ? try UnlockData(keyFile: keyData) : try UnlockData(masterPassword: password, keyFile: keyData)
            } else {
                unlock = UnlockData(masterPassword: password)
            }
            try await open(db, unlock: unlock)
            if faceIDEnabled, QuickUnlock.isAvailable { try? QuickUnlock.enroll(unlock, key: db.quickUnlockKey) }
        } catch {
            log.error("unlock failed: \(String(describing: error), privacy: .public)")
            unlockError = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    func unlockWithFaceID(_ db: SavedDatabase) async {
        guard canUseFaceID(db), !busy else { return }
        unlockError = nil
        do {
            let unlock = try await QuickUnlock.unlock(key: db.quickUnlockKey, reason: "Abrir \(db.name)")
            try await open(db, unlock: unlock)
        } catch QuickUnlock.Failure.cancelled {
            // Prefiere escribir la contraseña.
        } catch VaultError.wrongCredentials {
            QuickUnlock.forget(key: db.quickUnlockKey)
            unlockError = "La contraseña maestra ha cambiado. Escríbela para volver a activar \(biometryName)."
        } catch {
            unlockError = error.localizedDescription
        }
    }

    private func readKeyFile(_ db: SavedDatabase) throws -> Data? {
        guard let bookmark = db.keyFileBookmark else { return nil }
        let url = try Bookmarks.resolve(bookmark).url
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    private func open(_ db: SavedDatabase, unlock: UnlockData) async throws {
        busy = true
        defer { busy = false; unlockProgress = nil }
        await saveChain?.value
        let resolved = try Bookmarks.resolve(db.bookmark)
        var current = db
        if let refreshed = resolved.refreshed { current.bookmark = refreshed }
        let url = resolved.url
        let scoped = url.startAccessingSecurityScopedResource()
        let start = Date()
        unlockProgress = (start, db.unlockSeconds ?? 2, false)
        do {
            let opened = try await Task.detached(priority: .userInitiated) { try Vault.open(url: url, unlock: unlock) }.value
            current.unlockSeconds = Date().timeIntervalSince(start)
            update(current)
            unlockProgress?.done = true
            try? await Task.sleep(for: .milliseconds(220))
            if !scoped { /* archivo propio de la app: no necesita permiso */ }
            didOpen(opened, db: current, url: scoped ? url : nil)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    private func didOpen(_ opened: Vault, db: SavedDatabase, url: URL?) {
        accessedURL = url
        openDatabase = db
        unsaved = false
        withAnimation(Theme.spring) { vault = opened }
        version += 1
        if checkBreaches { Task { await checkPwned() } }
    }

    // MARK: - Bloquear

    /// Bloquea: quita la base de la memoria, borra el portapapeles si lo pusimos nosotros y cierra el acceso al archivo.
    func lock(manual: Bool = false) {
        guard let current = vault else { return }
        if unsaved { rescueUnsaved(current) }
        let pending = saveChain
        let url = accessedURL
        withAnimation(Theme.spring) { vault = nil }
        openDatabase = nil
        accessedURL = nil
        audit = nil
        auditVersion = -1
        pwned = [:]
        iconCache = [:]
        unsaved = false
        autoFaceID = !manual
        clearClipboardIfOurs()
        Task {
            await pending?.value
            url?.stopAccessingSecurityScopedResource()
        }
    }

    /// Si un guardado falló, deja los cambios en una copia cifrada (misma contraseña) dentro de la app.
    private func rescueUnsaved(_ vault: Vault) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Boveda/Sin guardar", isDirectory: true)
        do {
            try BackupStore(directory: folder).store(try vault.serialized(), for: vault.url)
            alert = AlertMessage(title: "Cambios sin guardar", message: "No se pudieron guardar en el archivo. Hay una copia cifrada dentro de Hush.")
        } catch {
            alert = AlertMessage(title: "Cambios perdidos", message: "No se pudieron guardar en el archivo ni en una copia: \(error.localizedDescription)")
        }
    }

    // MARK: - Ciclo de vida

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundedAt = Date()
            if autoLockSeconds == 0 { lock() }
        case .active:
            if let since = backgroundedAt, vault != nil, Date().timeIntervalSince(since) >= Double(autoLockSeconds) { lock() }
            backgroundedAt = nil
            if vault != nil { Task { await refreshIfChanged() } }
        default: break
        }
    }

    /// Si el archivo cambió desde otro dispositivo y aquí no hay nada pendiente, lo vuelve a leer.
    func refreshIfChanged() async {
        guard let current = vault, !unsaved, !saving else { return }
        let changed = await Task.detached { current.changedOnDisk() }.value
        guard changed else { return }
        await reload()
    }

    func reload() async {
        guard let current = vault else { return }
        do {
            let url = current.url, unlock = current.unlock
            let fresh = try await Task.detached(priority: .userInitiated) { try Vault.open(url: url, unlock: unlock) }.value
            guard vault?.url == url else { return }
            vault = fresh
            unsaved = false
            version += 1
            toast = Toast(symbol: "arrow.triangle.2.circlepath", message: "Actualizada con otro dispositivo")
        } catch {
            alert = AlertMessage(title: "No se ha podido recargar", message: error.localizedDescription)
        }
    }

    // MARK: - Cambios y guardado

    /// Aplica un cambio y lo guarda en el archivo.
    func mutate(_ body: (inout Vault) -> Void) {
        guard var current = vault else { return }
        body(&current)
        vault = current
        version += 1
        save()
    }

    /// Guarda en segundo plano, de uno en uno. Si iOS manda la app al fondo, termina igualmente.
    func save() {
        guard let snapshot = vault else { return }
        let previous = saveChain
        saving = true
        saveChain = Task { [weak self] in
            await previous?.value
            let background = UIApplication.shared.beginBackgroundTask(withName: "Guardar")
            defer { UIApplication.shared.endBackgroundTask(background) }
            let result: Result<Data, Error> = await Task.detached(priority: .userInitiated) {
                var copy = snapshot
                do { try copy.save(); return .success(copy.diskFingerprint) } catch { return .failure(error) }
            }.value
            guard let self else { return }
            self.saving = false
            switch result {
            case let .success(fingerprint):
                if self.vault?.url == snapshot.url {
                    self.vault?.adoptSavedFingerprint(fingerprint)
                    self.unsaved = false
                }
            case let .failure(error):
                guard self.vault?.url == snapshot.url else { return }
                self.unsaved = true
                if let error = error as? VaultError, error == .changedOnDisk {
                    self.alert = AlertMessage(title: "El archivo ha cambiado", message: "Se ha modificado desde otro dispositivo. Para no pisar esos cambios no se ha guardado. Recarga el archivo y vuelve a hacer el cambio.", reload: true)
                } else {
                    self.alert = AlertMessage(title: "No se ha guardado", message: error.localizedDescription)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    // MARK: - Portapapeles

    /// Copia solo en este iPhone (no pasa a otros dispositivos) y caduca sola.
    func copy(_ value: String, label: String) {
        guard !value.isEmpty else { return }
        let seconds = clipboardSeconds
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: value]], options: [
            .localOnly: true,
            .expirationDate: Date().addingTimeInterval(Double(seconds)),
        ])
        clipboardChange = UIPasteboard.general.changeCount
        toast = Toast(symbol: "checkmark", message: "\(label) copiada · se borra en \(seconds) s")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func clearClipboardIfOurs() {
        guard let change = clipboardChange, UIPasteboard.general.changeCount == change else { return }
        UIPasteboard.general.items = []
        clipboardChange = nil
    }

    // MARK: - Ayudas para las vistas

    var excluded: Set<UUID> { vault?.excludedFromBrowsing ?? [] }

    func entries(in groupID: UUID?) -> [KDBX.Entry] {
        guard let vault else { return [] }
        let base: [KDBX.Entry]
        if let groupID, let group = vault.root.group(groupID) {
            base = groupID == vault.recycleBinUUID ? group.allEntries() : group.allEntries(excluding: excluded)
        } else {
            base = vault.root.allEntries(excluding: excluded)
        }
        return base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func search(_ text: String) -> [KDBX.Entry] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return entries(in: nil).filter { entry in
            [entry.title, entry.userName, entry.url, entry.notes].contains { $0.localizedStandardContains(query) }
                || entry.tags.contains { $0.localizedStandardContains(query) }
        }
    }

    func icon(for entry: KDBX.Entry) -> UIImage? {
        guard let id = entry.customIconUUID else { return nil }
        if let cached = iconCache[id] { return cached }
        guard let data = vault?.customIconData(id), let image = UIImage(data: data) else { return nil }
        iconCache[id] = image
        return image
    }

    // MARK: - Auditoría

    /// Recalcula la auditoría en segundo plano si la base ha cambiado.
    func refreshAudit() {
        guard let vault, auditVersion != version else { return }
        let target = version
        auditVersion = target
        let entries = vault.root.allEntries(excluding: vault.excludedFromBrowsing)
        let pwned = self.pwned
        Task {
            let fresh = await Task.detached(priority: .userInitiated) {
                Audit(entries: entries, pwnedCount: { pwned[PwnedPasswords.sha1($0)].flatMap { $0 > 0 ? $0 : nil } })
            }.value
            guard self.auditVersion == target, self.vault != nil else { return }
            withAnimation(Theme.spring) { self.audit = fresh }
        }
    }

    /// Comprueba en Have I Been Pwned cada contraseña (solo viajan 5 caracteres de su huella).
    func checkPwned() async {
        guard checkBreaches, let vault, !pwnedChecking else { return }
        pwnedChecking = true
        defer { pwnedChecking = false }
        let hashes = Set(vault.root.allEntries(excluding: vault.excludedFromBrowsing)
            .filter { !$0.excludedFromAudit && $0.kind == .login }
            .map { $0.string(FieldKey.password) }.filter { !$0.isEmpty }
            .map(PwnedPasswords.sha1)).subtracting(pwned.keys)
        let url = vault.url
        await withTaskGroup(of: (String, Int?).self) { group in
            for hash in hashes {
                group.addTask { (hash, try? await PwnedPasswords.check(sha1: hash)) }
            }
            for await (hash, count) in group where self.vault?.url == url {
                if let count { pwned[hash] = count }
            }
        }
        guard self.vault?.url == url else { return }
        version += 1
    }
}
