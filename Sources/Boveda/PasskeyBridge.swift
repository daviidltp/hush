import AppKit
import BovedaCore
import KDBXKit

/// Claves de acceso (passkeys) desde el navegador: la extensión intercepta `navigator.credentials` y Hush
/// crea o firma con la clave guardada en la base. Cada operación se confirma en Hush.
///
/// Seguridad:
/// - El origen lo pone la extensión con la dirección que da el navegador, nunca la página.
/// - El rpId tiene que ser el dominio de esa página o uno de sus padres (sin sufijos públicos).
/// - Solo ES256. Si Hush no puede o no debe responder, la extensión deja seguir al navegador.
extension BrowserBridge {
    func passkey(_ type: String, _ message: [String: Any], model: AppModel) async -> [String: Any] {
        guard Preferences.passkeysEnabled else { return ["error": "disabled"] }
        guard let origin = message["origin"] as? String, let options = message["options"] as? [String: Any] else {
            return ["error": "bad-request"]
        }
        guard let challenge = Base64URL.decode(options["challenge"] as? String ?? ""), challenge.count >= 16 else {
            return ["error": "bad-request"]
        }
        let rpID = (type == "passkey-create" ? (options["rp"] as? [String: Any])?["id"] : options["rpId"]) as? String
            ?? URL(string: origin)?.host() ?? ""
        guard WebAuthn.isAllowed(rpID: rpID, origin: origin) else { return ["error": "security"] }

        // Base bloqueada: se abre Hush para desbloquearla y se espera un poco.
        if model.openVaults.isEmpty {
            model.showMainWindow()
            NSApp.activate()
            for _ in 0..<120 where model.openVaults.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
            guard !model.openVaults.isEmpty else { return ["error": "locked"] }
        }
        model.noteActivity()
        return type == "passkey-create"
            ? create(rpID: rpID, origin: origin, challenge: challenge, options: options, model: model)
            : get(rpID: rpID, origin: origin, challenge: challenge, options: options, model: model)
    }

    // MARK: Crear

    private func create(rpID: String, origin: String, challenge: Data, options: [String: Any], model: AppModel) -> [String: Any] {
        let algorithms = (options["pubKeyCredParams"] as? [[String: Any]] ?? []).compactMap { $0["alg"] as? Int }
        guard algorithms.isEmpty || algorithms.contains(-7) else { return ["error": "unsupported"] }
        guard let vault = model.vault else { return ["error": "locked"] }
        let user = options["user"] as? [String: Any] ?? [:]
        let userName = (user["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (user["displayName"] as? String ?? "")
        guard let userHandle = Base64URL.decode(user["id"] as? String ?? "") else { return ["error": "bad-request"] }
        let siteName = ((options["rp"] as? [String: Any])?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? rpID

        // Si ya hay una clave de esta web en la lista de excluidas, la web no quiere otra (InvalidStateError).
        let excluded = Set((options["excludeCredentials"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        if passkeys(for: rpID, in: model).contains(where: { excluded.contains($0.passkey.credentialIDText) }) {
            return ["error": "exists"]
        }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("¿Guardar una clave de acceso para \(rpID)?")
        alert.informativeText = L("Cuenta: \(userName.isEmpty ? L("sin nombre") : userName). Se guarda en «\(vault.name)» y podrás usarla para entrar sin contraseña, también desde el móvil con una app compatible con KeePass.")
        alert.addButton(withTitle: L("Guardar clave"))
        alert.addButton(withTitle: L("Cancelar"))
        guard alert.runModal() == .alertFirstButtonReturn else { return ["error": "cancelled"] }

        let passkey = Passkey.make(relyingParty: rpID, userName: userName, userHandle: userHandle)
        // Se añade a la entrada de esa web con el mismo usuario si existe y aún no tiene clave; si no, entrada nueva.
        let existing = vault.root.allEntries(excluding: vault.excludedFromBrowsing).first { entry in
            entry.kind == .login && !entry.hasPasskey && !userName.isEmpty
                && vault.resolve(entry.userName).caseInsensitiveCompare(userName) == .orderedSame
                && BrowserMatch.matches(page: origin, entry: entry, resolve: { vault.resolve($0) })
        }
        model.mutate { vault in
            if let existing {
                vault.updateEntry(existing.uuid) { passkey.write(into: &$0) }
            } else {
                var entry = KDBX.Entry.make(title: siteName)
                entry.set(FieldKey.userName, userName)
                entry.set(FieldKey.url, "https://\(rpID)")
                passkey.write(into: &entry)
                vault.addEntry(entry, to: vault.root.uuid)
            }
        }
        model.showToast(L("Clave de acceso guardada para \(rpID)"))

        let reply = passkey.registration(clientDataJSON: WebAuthn.clientData(.create, challenge: challenge, origin: origin))
        return [
            "id": Base64URL.encode(reply.credentialID),
            "clientDataJSON": Base64URL.encode(reply.clientDataJSON),
            "attestationObject": Base64URL.encode(reply.attestationObject),
            "authenticatorData": Base64URL.encode(reply.authenticatorData),
            "publicKey": Base64URL.encode(reply.publicKey),
            "publicKeyAlgorithm": -7,
        ]
    }

    // MARK: Usar

    private func get(rpID: String, origin: String, challenge: Data, options: [String: Any], model: AppModel) -> [String: Any] {
        let allowed = Set((options["allowCredentials"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        let candidates = passkeys(for: rpID, in: model).filter { allowed.isEmpty || allowed.contains($0.passkey.credentialIDText) }
        // Ninguna en Hush: que siga el navegador (otra app, una llave física…).
        guard !candidates.isEmpty else { return ["error": "none"] }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("¿Entrar en \(rpID) con una clave de acceso?")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        for candidate in candidates {
            let name = candidate.passkey.userName.isEmpty ? candidate.entry.title : candidate.passkey.userName
            picker.addItem(withTitle: model.openVaults.count > 1 ? "\(name) · \(candidate.vault.name)" : name)
        }
        if candidates.count > 1 {
            alert.informativeText = L("Elige la cuenta.")
            alert.accessoryView = picker
        } else {
            alert.informativeText = L("Cuenta: \(picker.titleOfSelectedItem ?? "")")
        }
        alert.addButton(withTitle: L("Entrar"))
        alert.addButton(withTitle: L("Cancelar"))
        guard alert.runModal() == .alertFirstButtonReturn else { return ["error": "cancelled"] }
        let chosen = candidates[max(0, picker.indexOfSelectedItem)]

        guard let reply = try? chosen.passkey.assertion(clientDataJSON: WebAuthn.clientData(.get, challenge: challenge, origin: origin)) else {
            return ["error": "failed"]
        }
        AppModel.markUsed(chosen.entry.uuid, in: chosen.vault.url)
        return [
            "id": Base64URL.encode(reply.credentialID),
            "clientDataJSON": Base64URL.encode(reply.clientDataJSON),
            "authenticatorData": Base64URL.encode(reply.authenticatorData),
            "signature": Base64URL.encode(reply.signature),
            "userHandle": Base64URL.encode(reply.userHandle),
        ]
    }

    private func passkeys(for rpID: String, in model: AppModel) -> [(vault: Vault, entry: KDBX.Entry, passkey: Passkey)] {
        model.openVaults.flatMap { vault in
            vault.root.allEntries(excluding: vault.excludedFromBrowsing).compactMap { entry -> (Vault, KDBX.Entry, Passkey)? in
                guard !vault.isInRecycleBin(entry.uuid), let passkey = entry.passkey,
                      passkey.relyingParty.caseInsensitiveCompare(rpID) == .orderedSame else { return nil }
                return (vault, entry, passkey)
            }
        }
    }
}
