import Foundation
import KDBXKit

// MARK: - Importar desde otras apps

/// Un elemento leído de un archivo exportado por otra app, antes de convertirlo en entrada KDBX.
public struct ImportedItem: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public var name: String
        public var value: String
        public var secret: Bool
    }

    public var kind: EntryKind = .login
    public var title = ""
    public var userName = ""
    public var password = ""
    public var url = ""
    public var notes = ""
    public var otp = ""
    /// Carpeta de origen, de fuera hacia dentro ("Trabajo/Bancos" → ["Trabajo", "Bancos"]).
    public var folder: [String] = []
    public var favorite = false
    public var tags: [String] = []
    public var fields: [Field] = []
    public var created: Date?
    public var modified: Date?

    public init() {}

    /// Para no importar dos veces lo mismo: web, usuario y contraseña (o título y notas si no hay contraseña).
    public var signature: String {
        let host = Self.host(url)
        return [kind.rawValue, host, userName.lowercased(), password, password.isEmpty ? title.lowercased() + "\u{1}" + notes : ""]
            .joined(separator: "\u{0}")
    }

    static func host(_ url: String) -> String {
        guard let host = BrowserMatch.host(of: url)?.lowercased() else { return url.lowercased() }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Formatos que se reconocen. El nombre solo se usa dentro (registro y tests): la interfaz no nombra otras apps.
public enum ImportFormat: String, Sendable {
    case bitwardenJSON, bitwardenCSV, onePasswordCSV, appleCSV, chromeCSV, firefoxCSV, protonCSV, keepassCSV, genericCSV
}

public struct ImportResult: Sendable {
    public let format: ImportFormat
    public var items: [ImportedItem]
    /// Filas que no se han podido leer (sin ningún dato útil).
    public var skipped: Int
}

public enum ImportError: LocalizedError, Equatable {
    case encrypted
    case unrecognized
    case empty

    public var errorDescription: String? {
        switch self {
        case .encrypted: return L("El archivo exportado está cifrado. Expórtalo otra vez sin cifrar (JSON o CSV) e impórtalo; después bórralo.")
        case .unrecognized: return L("No se reconoce el formato. Hush lee archivos CSV con cabecera y exportaciones JSON sin cifrar.")
        case .empty: return L("El archivo no tiene ninguna contraseña.")
        }
    }
}

public enum Importer {
    /// Lee un archivo exportado (CSV o JSON). No toca la base de datos.
    public static func read(_ data: Data) throws -> ImportResult {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.empty }
        let result: ImportResult
        if trimmed.hasPrefix("{") {
            result = try readJSON(data)
        } else {
            result = try readCSV(text)
        }
        guard !result.items.isEmpty else { throw ImportError.empty }
        return result
    }

    // MARK: JSON (exportación sin cifrar con "items" y "folders")

    private static func readJSON(_ data: Data) throws -> ImportResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ImportError.unrecognized }
        if root["encrypted"] as? Bool == true || root["encKeyValidation_DO_NOT_EDIT"] != nil { throw ImportError.encrypted }
        guard let rawItems = root["items"] as? [[String: Any]] else { throw ImportError.unrecognized }
        var folders: [String: [String]] = [:]
        for folder in root["folders"] as? [[String: Any]] ?? [] {
            if let id = folder["id"] as? String, let name = folder["name"] as? String {
                folders[id] = name.split(separator: "/").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: Any?) -> Date? {
            guard let text = value as? String else { return nil }
            return iso.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }

        var items: [ImportedItem] = []
        var skipped = 0
        for raw in rawItems {
            var item = ImportedItem()
            item.title = string(raw["name"])
            item.notes = string(raw["notes"])
            item.favorite = raw["favorite"] as? Bool ?? false
            item.folder = (raw["folderId"] as? String).flatMap { folders[$0] } ?? []
            item.created = date(raw["creationDate"])
            item.modified = date(raw["revisionDate"])
            let type = raw["type"] as? Int ?? 1
            switch type {
            case 1:
                let login = raw["login"] as? [String: Any] ?? [:]
                item.userName = string(login["username"])
                item.password = string(login["password"])
                item.otp = string(login["totp"])
                let uris = (login["uris"] as? [[String: Any]] ?? []).map { string($0["uri"]) }.filter { !$0.isEmpty }
                item.url = uris.first ?? ""
                for (index, uri) in uris.dropFirst().enumerated() {
                    item.fields.append(.init(name: "URL \(index + 2)", value: uri, secret: false))
                }
            case 3:
                item.kind = .card
                let card = raw["card"] as? [String: Any] ?? [:]
                let month = string(card["expMonth"]), year = string(card["expYear"])
                item.fields += [
                    .init(name: CardField.holder, value: string(card["cardholderName"]), secret: false),
                    .init(name: CardField.number, value: string(card["number"]), secret: true),
                    .init(name: CardField.expiry, value: expiry(month: month, year: year), secret: false),
                    .init(name: CardField.cvv, value: string(card["code"]), secret: true),
                ].filter { !$0.value.isEmpty }
                if item.title.isEmpty { item.title = string(card["brand"]) }
            case 2:
                item.kind = .note
            default:
                // Identidades y otros tipos: como nota segura con sus datos en campos.
                item.kind = .note
                let identity = raw["identity"] as? [String: Any] ?? [:]
                for (key, value) in identity.sorted(by: { $0.key < $1.key }) {
                    let text = string(value)
                    if !text.isEmpty { item.fields.append(.init(name: key, value: text, secret: false)) }
                }
            }
            for field in raw["fields"] as? [[String: Any]] ?? [] {
                let name = string(field["name"]), value = string(field["value"])
                guard !name.isEmpty || !value.isEmpty else { continue }
                item.fields.append(.init(name: name.isEmpty ? L("Campo") : name, value: value, secret: field["type"] as? Int == 1))
            }
            if isUseless(item) { skipped += 1 } else { items.append(finish(item)) }
        }
        return ImportResult(format: .bitwardenJSON, items: items, skipped: skipped)
    }

    // MARK: CSV

    private static func readCSV(_ text: String) throws -> ImportResult {
        let rows = csvRows(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }), header.count >= 2 else {
            throw ImportError.unrecognized
        }
        let has = Set(header)
        let format: ImportFormat
        if has.isSuperset(of: ["login_uri", "login_username"]) {
            format = .bitwardenCSV
        } else if has.isSuperset(of: ["httprealm", "formactionorigin"]) {
            format = .firefoxCSV
        } else if has.isSuperset(of: ["email", "vault", "totp"]) && has.contains("name") {
            format = .protonCSV
        } else if has.contains("otpauth") && (has.contains("archived") || has.contains("tags")) {
            format = .onePasswordCSV
        } else if has.contains("otpauth") {
            format = .appleCSV
        } else if has.contains("group") && has.contains("title") {
            format = .keepassCSV
        } else if has.isSuperset(of: ["name", "url", "username", "password"]) {
            format = .chromeCSV
        } else {
            format = .genericCSV
        }

        // Cada columna se busca por sus nombres habituales; así casi cualquier CSV con cabecera sirve.
        func column(_ names: [String]) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        let title = column(["title", "name", "nombre", "título", "titulo"])
        let user = column(["login_username", "username", "user", "login", "usuario", "user name", "email address"])
        let email = column(["email", "e-mail", "correo"])
        let password = column(["login_password", "password", "pass", "contraseña", "contrasena"])
        let url = column(["login_uri", "url", "website", "web site", "uri", "web", "login url"])
        let notes = column(["notes", "note", "notas", "nota", "comments", "extra"])
        let otp = column(["login_totp", "otpauth", "totp", "otp", "2fa"])
        let folder = column(["folder", "group", "vault", "grouping", "category", "carpeta", "grupo"])
        let favorite = column(["favorite", "favourite", "fav"])
        let tags = column(["tags", "etiquetas"])
        let type = column(["type"])
        let extra = column(["fields"])
        let created = column(["created", "timecreated", "createtime"])
        let modified = column(["last modified", "modified", "timepasswordchanged", "modifytime"])
        guard password != nil || notes != nil else { throw ImportError.unrecognized }

        var items: [ImportedItem] = []
        var skipped = 0
        for row in rows.dropFirst() where !(row.count == 1 && row[0].isEmpty) {
            func value(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var item = ImportedItem()
            item.title = value(title)
            item.userName = value(user)
            item.password = row.indices.contains(password ?? -1) ? row[password!] : ""
            item.url = value(url)
            item.notes = value(notes)
            item.otp = value(otp)
            let emailValue = value(email)
            if item.userName.isEmpty { item.userName = emailValue } else if !emailValue.isEmpty && emailValue != item.userName {
                item.fields.append(.init(name: "Email", value: emailValue, secret: false))
            }
            // Las carpetas anidadas vienen separadas por «/».
            item.folder = value(folder).split(separator: [.keepassCSV, .bitwardenCSV].contains(format) ? "/" : "\u{0}")
                .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // El CSV de las bases KeePass incluye la raíz como primera carpeta: no se repite.
            if format == .keepassCSV, !item.folder.isEmpty { item.folder.removeFirst() }
            item.favorite = ["1", "true", "yes", "sí", "si"].contains(value(favorite).lowercased())
            item.tags = value(tags).split(whereSeparator: { $0 == "," || $0 == ";" }).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if value(type).lowercased() == "note" { item.kind = .note }
            // Campos extra en el formato "nombre: valor", uno por línea.
            for line in value(extra).split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                item.fields.append(.init(name: String(parts[0]).trimmingCharacters(in: .whitespaces),
                                         value: String(parts[1]).trimmingCharacters(in: .whitespaces), secret: false))
            }
            item.created = date(value(created))
            item.modified = date(value(modified))
            if isUseless(item) { skipped += 1 } else { items.append(finish(item)) }
        }
        return ImportResult(format: format, items: items, skipped: skipped)
    }

    /// Lector de CSV (RFC 4180): comillas, comillas dobles escapadas y saltos de línea dentro de un campo.
    public static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(text.unicodeScalars).makeIterator()
        var pending: Unicode.Scalar? = iterator.next()
        while let char = pending {
            pending = iterator.next()
            if quoted {
                if char == "\"" {
                    if pending == "\"" { field.unicodeScalars.append("\""); pending = iterator.next() } else { quoted = false }
                } else {
                    field.unicodeScalars.append(char)
                }
                continue
            }
            switch char {
            case "\"" where field.isEmpty: quoted = true
            case ",": row.append(field); field = ""
            case "\r": continue
            case "\n": row.append(field); rows.append(row); row = []; field = ""
            default: field.unicodeScalars.append(char)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: Ayudas

    private static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        default: return ""
        }
    }

    private static func expiry(month: String, year: String) -> String {
        guard !month.isEmpty || !year.isEmpty else { return "" }
        let mm = month.count == 1 ? "0" + month : month
        let yy = year.count == 4 ? String(year.suffix(2)) : year
        return [mm, yy].filter { !$0.isEmpty }.joined(separator: "/")
    }

    private static func date(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        if let seconds = Double(text) {
            // Marcas de tiempo en milisegundos (las más habituales) o en segundos.
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        }
        return ISO8601DateFormatter().date(from: text)
    }

    private static func isUseless(_ item: ImportedItem) -> Bool {
        item.title.isEmpty && item.userName.isEmpty && item.password.isEmpty && item.url.isEmpty && item.notes.isEmpty && item.fields.isEmpty
    }

    private static func finish(_ item: ImportedItem) -> ImportedItem {
        var item = item
        if item.title.isEmpty {
            let host = ImportedItem.host(item.url)
            item.title = host.isEmpty ? L("Sin título") : host
        }
        return item
    }
}

// MARK: - Pasar a la base de datos

public extension ImportedItem {
    /// Entrada KDBX con los mismos campos que usaría Hush al crearla a mano.
    func makeEntry() -> KDBX.Entry {
        var entry = KDBX.Entry.make(title: title)
        entry.set(FieldKey.userName, userName)
        entry.set(FieldKey.password, password, protected: true)
        entry.set(FieldKey.url, url)
        entry.set(FieldKey.notes, notes)
        if !otp.isEmpty {
            // Se guarda como enlace otpauth (lo que leen las apps KeePass); una clave suelta se convierte.
            let value = otp.lowercased().hasPrefix("otpauth://") ? otp : TOTP.parse(otp).map { _ in
                "otpauth://totp/\(title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "Hush")?secret=\(otp.uppercased().filter { !$0.isWhitespace })"
            } ?? ""
            if !value.isEmpty { entry.set(FieldKey.otp, value, protected: true) }
        }
        var used = FieldKey.standard.union(TOTP.fieldKeys)
        for field in fields {
            var name = field.name
            var suffix = 2
            while used.contains(name) { name = "\(field.name) \(suffix)"; suffix += 1 }
            used.insert(name)
            entry.set(name, field.value, protected: field.secret)
        }
        entry.setKind(kind)
        entry.tags = tags + (favorite ? [favoriteTag] : [])
        if let created { entry.times?.creationTime = created }
        if let modified { entry.times?.lastModificationTime = modified }
        return entry
    }
}

public extension Vault {
    /// Firmas de lo que ya hay, para saltarse duplicados al importar.
    var importSignatures: Set<String> {
        Set(root.allEntries(excluding: excludedFromBrowsing).map { entry in
            var item = ImportedItem()
            item.kind = entry.kind
            item.title = entry.title
            item.userName = entry.userName
            item.password = entry.string(FieldKey.password)
            item.url = entry.url
            item.notes = entry.notes
            return item.signature
        })
    }

    /// Mete los elementos en un grupo nuevo (con sus carpetas como subgrupos). Devuelve el grupo creado.
    @discardableResult
    mutating func importItems(_ items: [ImportedItem], intoGroupNamed name: String) -> UUID {
        let top = addGroup(named: name, to: root.uuid)
        var folders: [[String]: UUID] = [[]: top]
        func group(for path: [String]) -> UUID {
            if let id = folders[path] { return id }
            let parent = group(for: Array(path.dropLast()))
            let id = addGroup(named: path.last!, to: parent)
            folders[path] = id
            return id
        }
        for item in items {
            addEntry(item.makeEntry(), to: group(for: item.folder))
        }
        return top
    }
}
