import Foundation
import BovedaCore
import KDBXKit

/// «¿Guardar en Hush?»: la extensión detecta que has entrado o te has registrado en una web y ofrece guardar
/// (o actualizar) la cuenta. El panel está en la página; aquí se decide qué ofrecer y se guarda.
///
/// Seguridad:
/// - La dirección de la página la pone la extensión con la que da el navegador, nunca la página.
/// - Solo se actualizan entradas de esa misma web, y la web de una entrada nueva tiene que ser del mismo sitio.
/// - Se guarda con `mutate`, como al editar: historial, copia previa, comprobar que el archivo se reabre
///   y no escribir encima si cambió fuera.
extension BrowserBridge {
    /// Sitio (dominio registrable) de una dirección: la extensión lo usa para no enseñar el panel en otra web.
    func site(_ message: [String: Any]) -> [String: Any] {
        guard let host = BrowserMatch.host(of: message["url"] as? String ?? "") else { return ["error": "bad-request"] }
        return ["site": BrowserMatch.site(of: host)]
    }

    /// Se avisa a Ajustes → Navegadores cuando la extensión añade una web a «No preguntar».
    static let neverSaveChanged = Notification.Name("HushNeverSaveChanged")

    /// ¿Se ofrece guardar en esta web? Lo decide el ajuste de Hush y la lista de «No preguntar».
    /// La extensión lo pregunta antes de capturar nada: si es que no, la contraseña ni sale de la página.
    static func offersToSave(on page: String) -> Bool {
        guard Preferences.offerToSaveLogins, let site = SaveLogin.siteKey(for: page) else { return false }
        return !Preferences.neverSaveSites.contains(site)
    }

    func saveSettings(_ message: [String: Any]) -> [String: Any] {
        ["enabled": Self.offersToSave(on: message["url"] as? String ?? "")]
    }

    /// «No preguntar en esta web»: se guarda en Hush, por dominio registrable.
    func neverSave(_ message: [String: Any]) -> [String: Any] {
        guard let site = SaveLogin.siteKey(for: message["url"] as? String ?? "") else { return ["error": "bad-request"] }
        Preferences.neverSaveSites = SaveLogin.adding(site, to: Preferences.neverSaveSites)
        NotificationCenter.default.post(name: Self.neverSaveChanged, object: nil)
        return ["ok": true]
    }

    /// Qué ofrecer para lo que acabas de escribir en una web: nada (ya está), actualizar o guardar nueva.
    /// Con Hush bloqueada no se puede saber: se ofrece guardar y se vuelve a mirar al desbloquear.
    func saveCheck(_ message: [String: Any], model: AppModel) -> [String: Any] {
        let page = message["url"] as? String ?? ""
        let user = message["user"] as? String ?? ""
        let password = message["password"] as? String ?? ""
        guard !password.isEmpty, let host = BrowserMatch.host(of: page) else { return ["error": "bad-request"] }
        guard Self.offersToSave(on: page) else { return ["disabled": true] }
        var reply: [String: Any] = [
            "site": BrowserMatch.site(of: host),
            "title": SaveLogin.defaultTitle(for: page),
            "web": SaveLogin.defaultURL(for: page),
        ]
        guard let active = model.vault else {
            reply["locked"] = true
            return reply
        }
        // En cualquiera de las bases abiertas: si ya está, no se pregunta.
        if model.openVaults.contains(where: { SaveLogin.decide(page: page, user: user, password: password, in: $0) == .known }) {
            return ["known": true, "site": reply["site"]!]
        }
        // Solo se actualiza en la base activa (es la que se guarda).
        if case let .update(id) = SaveLogin.decide(page: page, user: user, password: password, in: active),
           let entry = active.locate(id)?.entry {
            reply["update"] = ["uuid": id.uuidString, "vault": active.url.path, "title": entry.title]
        }
        reply["vaultName"] = active.name
        reply["groups"] = active.root.flattened(excluding: active.excludedFromBrowsing).map { item in
            ["id": item.group.uuid.uuidString, "name": item.level == 0 ? active.name : item.group.displayName, "level": item.level] as [String: Any]
        }
        return reply
    }

    /// Al pulsar «Guardar» con Hush bloqueada: pide Touch ID como «Desbloquear» en la barra de menús.
    /// Si no hay huella o se cancela, se abre la ventana con la contraseña.
    func unlockForSave(model: AppModel) async -> [String: Any] {
        if model.vault == nil { _ = await model.unlockFromMenuBar() }
        return ["locked": model.vault == nil]
    }

    func saveLogin(_ message: [String: Any], model: AppModel) async -> [String: Any] {
        let page = message["url"] as? String ?? ""
        guard Self.offersToSave(on: page) else { return ["error": "disabled"] }
        guard let active = model.vault else { return ["locked": true] }
        func text(_ key: String, limit: Int = 1024) -> String {
            String((message[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        let password = message["password"] as? String ?? ""
        guard !password.isEmpty, password.count <= 4096, BrowserMatch.host(of: page) != nil else { return ["error": "bad-request"] }

        let id: UUID
        if let uuidText = message["uuid"] as? String {
            // Actualizar: la entrada tiene que seguir ahí y ser de esta misma web.
            guard let found = UUID(uuidString: uuidText), message["vault"] as? String == active.url.path,
                  let entry = active.locate(found)?.entry, entry.kind == .login, !active.isInRecycleBin(found),
                  BrowserMatch.matches(page: page, entry: entry, resolve: { active.resolve($0) }) else { return ["error": "not-found"] }
            id = found
            model.mutate { $0.updateEntry(id) { $0.set(FieldKey.password, password, protected: true) } }
            guard model.vault?.locate(id)?.entry.string(FieldKey.password) == password else { return ["error": "busy"] }
        } else {
            let web = text("web").isEmpty ? SaveLogin.defaultURL(for: page) : text("web")
            guard SaveLogin.sameSite(web, page: page) else { return ["error": "other-site"] }
            let groups = Set(active.root.flattened(excluding: active.excludedFromBrowsing).map(\.group.uuid))
            let group = (message["group"] as? String).flatMap(UUID.init(uuidString:)) ?? active.root.uuid
            guard groups.contains(group) else { return ["error": "not-found"] }
            let title = text("title").isEmpty ? SaveLogin.defaultTitle(for: page) : text("title")
            let entry = SaveLogin.makeEntry(title: title, user: text("user"), password: password, url: web,
                                            notes: String((message["notes"] as? String ?? "").prefix(65536)))
            id = entry.uuid
            model.mutate { $0.addEntry(entry, to: group) }
            guard model.vault?.locate(id) != nil else { return ["error": "busy"] }
        }
        model.noteActivity()
        AppModel.markUsed(id, in: active.url)
        // Se espera a que esté escrito (y comprobado) en el archivo. Si falla, Hush avisa y lo pone a salvo como siempre.
        await model.flushSaves()
        return ["ok": true, "saved": !model.unsavedURLs.contains(active.url)]
    }
}
