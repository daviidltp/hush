import Foundation
import KDBXKit

/// Guardar desde el navegador lo que escribes al entrar o registrarte en una web.
/// Decide si Hush ya lo tiene, si hay que actualizar la contraseña de una entrada o si es una cuenta nueva.
public enum SaveLogin {
    public enum Decision: Equatable {
        /// Ya está en Hush con esa contraseña: no se pregunta nada.
        case known
        /// Hay una entrada de esa web y ese usuario con otra contraseña.
        case update(UUID)
        /// Cuenta nueva.
        case new
    }

    /// Entradas de inicio de sesión de esa web con ese usuario (sin mirar la papelera).
    public static func candidates(page: String, user: String, in vault: Vault) -> [KDBX.Entry] {
        vault.root.allEntries(excluding: vault.excludedFromBrowsing).filter { entry in
            entry.kind == .login
                && vault.resolve(entry.userName).caseInsensitiveCompare(user) == .orderedSame
                && BrowserMatch.matches(page: page, entry: entry, resolve: { vault.resolve($0) })
        }
    }

    public static func decide(page: String, user: String, password: String, in vault: Vault) -> Decision {
        let found = candidates(page: page, user: user, in: vault)
        if found.contains(where: { vault.resolve($0.string(FieldKey.password)) == password }) { return .known }
        // Si hay varias, la que usaste o cambiaste por última vez.
        let latest = found.max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        return latest.map { .update($0.uuid) } ?? .new
    }

    /// Título propuesto: el dominio de la web («accounts.google.com» → «google.com»).
    public static func defaultTitle(for page: String) -> String {
        guard let host = BrowserMatch.host(of: page) else { return "" }
        return BrowserMatch.site(of: host)
    }

    /// Web que se guarda: la dirección de la página sin ruta ni parámetros («https://github.com»).
    public static func defaultURL(for page: String) -> String {
        guard let address = BrowserMatch.address(of: page) else { return "" }
        let host = address.host.hasPrefix("www.") ? String(address.host.dropFirst(4)) : address.host
        return "\(address.scheme)://\(host)"
    }

    /// La web que escribes en el panel tiene que ser del mismo sitio que la página: una página no puede
    /// guardar (ni hacerte guardar) contraseñas a nombre de otra web.
    public static func sameSite(_ web: String, page: String) -> Bool {
        BrowserMatch.matches(page: page, entryURL: web)
    }

    /// Entrada nueva lista para añadir a la base.
    public static func makeEntry(title: String, user: String, password: String, url: String, notes: String) -> KDBX.Entry {
        var entry = KDBX.Entry.make(title: title)
        entry.set(FieldKey.userName, user)
        entry.set(FieldKey.password, password, protected: true)
        entry.set(FieldKey.url, url)
        entry.set(FieldKey.notes, notes)
        return entry
    }
}
