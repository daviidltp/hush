import BovedaCore
import Foundation
import SwiftUI

/// Una base que el usuario ha abierto alguna vez con el selector de documentos.
/// No guarda nada secreto: solo el marcador para volver a abrir el archivo (y el de su archivo de clave).
struct SavedDatabase: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var location: String
    var bookmark: Data
    var keyFileBookmark: Data?
    var keyFileName: String?
    /// Lo que tardó en abrirse la última vez, para la barra de progreso.
    var unlockSeconds: Double?

    /// Clave con la que Face ID guarda su registro: propia, porque la ruta de un archivo de iCloud o Dropbox puede cambiar.
    var quickUnlockKey: String { "ios:" + id.uuidString }
}

enum Bookmarks {
    /// Crea el marcador de un archivo elegido en el selector de documentos.
    static func make(for url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resuelve un marcador. Si estaba caducado, devuelve también uno nuevo para guardarlo.
    static func resolve(_ data: Data) throws -> (url: URL, refreshed: Data?) {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale ? try? make(for: url) : nil)
    }

    /// Dónde está el archivo, en palabras («iCloud Drive», «En mi iPhone»…).
    static func locationName(_ url: URL) -> String {
        let path = url.path
        if path.contains("/Mobile Documents/") { return "iCloud Drive" }
        if path.contains("/File Provider Storage/") { return "En mi iPhone" }
        if path.contains("/Containers/Data/Application/") || path.contains("/Documents/") && path.contains("/Application/") { return "Hush" }
        if let provider = url.pathComponents.first(where: { $0.contains(".") && $0.hasPrefix("com.") }) {
            let name = provider.split(separator: ".").dropFirst().first.map { String($0).capitalized } ?? provider
            return name
        }
        return "Archivos"
    }
}

/// Grupo de apps compartido con la extensión de autorrelleno: lista de bases, ajustes y registros de Face ID.
enum AppGroup {
    static let id = "group.com.david.hush"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// Prepara lo compartido. Se llama al arrancar la app y la extensión.
    static func configure() {
        // Las claves de Face ID van en el llavero compartido (ver BiometricKeychain).
        migrateLocalPreferences()
    }

    /// Las primeras versiones de prueba se instalaron sin el grupo: sus ajustes quedaron en la carpeta
    /// de la app. Si el grupo está vacío, se pasan a él una vez y se borra el archivo viejo.
    private static func migrateLocalPreferences() {
        guard container != nil, let shared = UserDefaults(suiteName: id) else { return }
        let old = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Preferences/\(id).plist")
        guard shared.object(forKey: "databases") == nil,
              let data = try? Data(contentsOf: old),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              values["databases"] != nil else { return }
        for (key, value) in values { shared.set(value, forKey: key) }
        try? FileManager.default.removeItem(at: old)
    }
}

/// Ajustes de la app (no secretos). Viven en el grupo de apps para que la extensión los lea.
enum Preferences {
    private static let defaults = UserDefaults(suiteName: AppGroup.id) ?? .standard

    static var databases: [SavedDatabase] {
        get { (defaults.data(forKey: "databases")).flatMap { try? JSONDecoder().decode([SavedDatabase].self, from: $0) } ?? [] }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "databases") }
    }

    static var lastDatabase: UUID? {
        get { defaults.string(forKey: "lastDatabase").flatMap(UUID.init) }
        set { defaults.set(newValue?.uuidString, forKey: "lastDatabase") }
    }

    /// Segundos fuera de la app antes de bloquear (0 = al momento).
    static var autoLockSeconds: Int {
        get { defaults.object(forKey: "autoLockSeconds") as? Int ?? 0 }
        set { defaults.set(newValue, forKey: "autoLockSeconds") }
    }

    static var clipboardSeconds: Int {
        get { defaults.object(forKey: "clipboardSeconds") as? Int ?? 30 }
        set { defaults.set(newValue, forKey: "clipboardSeconds") }
    }

    static var faceIDEnabled: Bool {
        get { defaults.object(forKey: "faceIDEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "faceIDEnabled") }
    }

    /// Comprobar filtraciones en internet (solo viajan 5 caracteres de la huella de cada contraseña).
    /// Logos de las webs (se descargan de cada web, sin servicios de terceros).
    static var showFavicons: Bool {
        get { defaults.object(forKey: "showFavicons") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showFavicons") }
    }

    static var checkBreaches: Bool {
        get { defaults.object(forKey: "checkBreaches") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "checkBreaches") }
    }

    static var generator: GeneratorOptions {
        get { defaults.data(forKey: "generator").flatMap { try? JSONDecoder().decode(GeneratorOptions.self, from: $0) } ?? GeneratorOptions() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "generator") }
    }

    /// Entradas abiertas hace poco, por base (solo identificadores).
    static func recents(for database: UUID) -> [UUID] {
        (defaults.stringArray(forKey: "recents-" + database.uuidString) ?? []).compactMap(UUID.init)
    }

    static func setRecents(_ ids: [UUID], for database: UUID) {
        defaults.set(ids.map(\.uuidString), forKey: "recents-" + database.uuidString)
    }

    /// Cómo se ve la lista: carpetas que se abren o todo junto con píldoras arriba.
    static var browseStyle: BrowseStyle {
        get { BrowseStyle(rawValue: defaults.string(forKey: "browseStyle") ?? "") ?? .folders }
        set { defaults.set(newValue.rawValue, forKey: "browseStyle") }
    }

    static var appearance: Appearance {
        get { Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearance") }
    }
}

enum BrowseStyle: String, CaseIterable {
    case folders, chips
    var label: String { self == .folders ? "Carpetas" : "Todo junto" }
}

enum Appearance: String, CaseIterable {
    case system, light, dark
    var label: String {
        switch self {
        case .system: return "Automático"
        case .light: return "Claro"
        case .dark: return "Oscuro"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
