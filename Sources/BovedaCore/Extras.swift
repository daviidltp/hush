import CryptoKit
import Foundation
import KDBXKit

// MARK: - Tipos de entrada

/// KDBX no tiene tipos: se guarda en los datos propios de la entrada (invisibles para otras apps)
/// y los campos son campos personalizados normales, así se leen en cualquier app KeePass.
public enum EntryKind: String, CaseIterable, Sendable {
    case login, card, note

    public var label: String {
        switch self {
        case .login: return "Inicio de sesión"
        case .card: return "Tarjeta"
        case .note: return "Nota segura"
        }
    }

    public var symbol: String {
        switch self {
        case .login: return "key.horizontal"
        case .card: return "creditcard"
        case .note: return "note.text"
        }
    }
}

public enum CardField {
    public static let holder = "Titular"
    public static let number = "Número de tarjeta"
    public static let expiry = "Caducidad"
    public static let cvv = "CVV"
    public static let pin = "PIN"
    public static let all = [holder, number, expiry, cvv, pin]
    public static let secret: Set<String> = [number, cvv, pin]
}

public extension KDBX.Entry {
    static let kindKey = "Boveda_Tipo"

    var kind: EntryKind {
        if let value = customData.first(where: { $0.key == Self.kindKey })?.value, let kind = EntryKind(rawValue: value) { return kind }
        if strings.contains(where: { $0.key == CardField.number }) { return .card }
        return .login
    }

    mutating func setKind(_ kind: EntryKind) {
        customData.removeAll { $0.key == Self.kindKey }
        if kind != .login { customData.append(KDBX.CustomDataItem(key: Self.kindKey, value: kind.rawValue)) }
    }

    /// Excluida de la auditoría (campo estándar de KeePass, lo respetan las demás apps).
    var excludedFromAudit: Bool { qualityCheck == false }

    /// Cuándo se puso la contraseña actual, mirando el historial.
    var passwordChangedDate: Date? {
        let versions = history + [self]
        let current = string(FieldKey.password)
        var index = versions.count - 1
        while index > 0, versions[index - 1].string(FieldKey.password) == current { index -= 1 }
        if index == 0 { return versions[0].times?.creationTime ?? versions[0].times?.lastModificationTime }
        return versions[index].times?.lastModificationTime
    }

    /// Correo de la entrada: el usuario si es un email, o un campo llamado "Email"/"Correo".
    var email: String? {
        if userName.contains("@") { return userName }
        let field = strings.first { ["email", "e-mail", "correo"].contains($0.key.lowercased()) }
        return field?.value.revealedString
    }
}

// MARK: - Referencias entre campos ({REF:P@I:…} de KeePass)

public enum FieldReference {
    static let fields: [Character: String] = ["T": FieldKey.title, "U": FieldKey.userName, "P": FieldKey.password, "A": FieldKey.url, "N": FieldKey.notes]

    /// Texto para pegar en otra entrada: apunta a este campo de esta entrada.
    public static func make(field: Character, to entry: KDBX.Entry) -> String {
        "{REF:\(field)@I:\(entry.uuid.uuidString.replacingOccurrences(of: "-", with: ""))}"
    }

    public static func contains(_ value: String) -> Bool { value.range(of: "{REF:", options: .caseInsensitive) != nil }
}

public extension Vault {
    /// Sustituye las referencias {REF:campo@buscarEn:texto} por el valor real (hasta 5 niveles).
    func resolve(_ value: String, depth: Int = 0) -> String {
        guard FieldReference.contains(value), depth < 5,
              let regex = try? NSRegularExpression(pattern: "\\{REF:([TUPAN])@([TUPANI]):([^}]*)\\}", options: .caseInsensitive) else { return value }
        var result = value
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed()
        let entries = root.allEntries()
        for match in matches {
            guard let whole = Range(match.range, in: value), let f = Range(match.range(at: 1), in: value),
                  let s = Range(match.range(at: 2), in: value), let t = Range(match.range(at: 3), in: value),
                  let wanted = FieldReference.fields[Character(value[f].uppercased())] else { continue }
            let searchIn = Character(value[s].uppercased())
            let text = String(value[t])
            let target: KDBX.Entry?
            if searchIn == "I" {
                let id = text.replacingOccurrences(of: "-", with: "").uppercased()
                target = entries.first { $0.uuid.uuidString.replacingOccurrences(of: "-", with: "") == id }
            } else if let key = FieldReference.fields[searchIn] {
                target = entries.first { $0.string(key).localizedCaseInsensitiveContains(text) }
            } else {
                target = nil
            }
            guard let target, let range = Range(NSRange(whole, in: value), in: result) else { continue }
            result.replaceSubrange(range, with: resolve(target.string(wanted), depth: depth + 1))
        }
        return result
    }
}

// MARK: - Historial

public struct FieldChange: Identifiable, Equatable {
    public var id: String { key }
    public let key: String
    public let label: String
    public let old: String
    public let new: String
    public let secret: Bool
}

public extension KDBX.Entry {
    static func label(for key: String) -> String {
        switch key {
        case FieldKey.title: return "Título"
        case FieldKey.userName: return "Usuario"
        case FieldKey.password: return "Contraseña"
        case FieldKey.url: return "Web"
        case FieldKey.notes: return "Notas"
        case FieldKey.otp: return "Código 2FA"
        default: return key
        }
    }

    /// Qué cambia de esta versión (antigua) a `newer`.
    func changes(to newer: KDBX.Entry) -> [FieldChange] {
        var keys: [String] = [FieldKey.title, FieldKey.userName, FieldKey.password, FieldKey.url, FieldKey.notes]
        for key in (strings + newer.strings).map(\.key) where !keys.contains(key) { keys.append(key) }
        var list: [FieldChange] = keys.compactMap { key in
            let a = string(key), b = newer.string(key)
            guard a != b else { return nil }
            let secret = key == FieldKey.password || isProtected(key) || newer.isProtected(key)
            return FieldChange(key: key, label: Self.label(for: key), old: a, new: b, secret: secret)
        }
        let tagsA = tags.filter { $0 != favoriteTag }.joined(separator: ", ")
        let tagsB = newer.tags.filter { $0 != favoriteTag }.joined(separator: ", ")
        if tagsA != tagsB { list.append(FieldChange(key: "#tags", label: "Etiquetas", old: tagsA, new: tagsB, secret: false)) }
        let filesA = binaries.map(\.key).joined(separator: ", ")
        let filesB = newer.binaries.map(\.key).joined(separator: ", ")
        if filesA != filesB { list.append(FieldChange(key: "#files", label: "Adjuntos", old: filesA, new: filesB, secret: false)) }
        let expiryA = Self.expiryText(self), expiryB = Self.expiryText(newer)
        if expiryA != expiryB { list.append(FieldChange(key: "#expiry", label: "Caducidad", old: expiryA, new: expiryB, secret: false)) }
        return list
    }

    /// «Nunca» o la fecha de caducidad, para comparar versiones.
    static func expiryText(_ entry: KDBX.Entry) -> String {
        guard entry.times?.expires == true, let date = entry.times?.expiryTime else { return "Nunca" }
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(Locale(identifier: "es_ES")))
    }
}

public extension Vault {
    /// Vuelve a una versión anterior. La versión actual pasa al historial, así que se puede deshacer.
    mutating func restoreHistory(_ index: Int, of id: UUID) {
        guard let entry = locate(id)?.entry, entry.history.indices.contains(index) else { return }
        let old = entry.history[index]
        updateEntry(id) { current in
            current.strings = old.strings
            current.tags = current.isFavorite && !old.tags.contains(favoriteTag) ? old.tags + [favoriteTag] : old.tags
            current.binaries = old.binaries
            current.customIconUUID = old.customIconUUID
            current.iconID = old.iconID
            current.customData = old.customData
            current.times?.expires = old.times?.expires
            current.times?.expiryTime = old.times?.expiryTime
        }
    }

    /// Borra una versión antigua del historial.
    mutating func deleteHistory(_ index: Int, of id: UUID) {
        root.mutateEntry(id) { entry in
            guard entry.history.indices.contains(index) else { return }
            entry.history.remove(at: index)
        }
        compactAttachments()
    }
}

// MARK: - Iconos propios

public extension Vault {
    /// Pone un icono propio (PNG) a la entrada, o lo quita con nil. Viaja dentro del archivo, así se ve también en el móvil.
    mutating func setCustomIcon(_ png: Data?, for id: UUID) {
        var iconID: UUID?
        if let png {
            if let existing = content.database.meta.customIcons.first(where: { $0.data == png }) {
                iconID = existing.uuid
            } else {
                let icon = KDBX.CustomIcon(uuid: UUID(), data: png, name: nil, lastModificationTime: Date())
                content.database.meta.customIcons.append(icon)
                iconID = icon.uuid
            }
        }
        root.mutateEntry(id) { entry in
            entry.customIconUUID = iconID
            entry.times?.lastModificationTime = Date()
        }
        pruneCustomIcons()
    }

    /// Quita del archivo los iconos que ya no usa nadie.
    mutating func pruneCustomIcons() {
        var used = Set<UUID>()
        func collect(_ entry: KDBX.Entry) {
            if let id = entry.customIconUUID { used.insert(id) }
            entry.history.forEach(collect)
        }
        func walk(_ group: KDBX.Group) {
            if let id = group.customIconUUID { used.insert(id) }
            group.entries.forEach(collect)
            group.groups.forEach(walk)
        }
        walk(root)
        let icons = content.database.meta.customIcons
        let kept = icons.filter { used.contains($0.uuid) }
        if kept.count != icons.count { content.database.meta.customIcons = kept }
    }

    func customIconData(_ id: UUID?) -> Data? {
        guard let id else { return nil }
        return content.database.meta.customIcons.first { $0.uuid == id }?.data
    }
}

// MARK: - Copiar una entrada a otra base

/// Una entrada completa (con adjuntos e icono) lista para pegarse en otra base.
public struct EntryPackage {
    public let entry: KDBX.Entry
    public let attachments: [(name: String, data: Data)]
    public let icon: Data?
}

public extension Vault {
    func package(_ id: UUID) -> EntryPackage? {
        guard let entry = locate(id)?.entry else { return nil }
        let files = attachments(of: entry).compactMap { file in attachmentData(named: file.name, in: entry).map { (file.name, $0) } }
        return EntryPackage(entry: entry, attachments: files, icon: customIconData(entry.customIconUUID))
    }

    /// Pega una copia nueva (sin historial) en el grupo indicado. Devuelve su ID.
    @discardableResult
    mutating func paste(_ package: EntryPackage, into groupID: UUID) -> UUID {
        var entry = package.entry
        entry.uuid = UUID()
        entry.history = []
        entry.binaries = []
        entry.customIconUUID = nil
        let now = Date()
        entry.times = KDBX.Times(creationTime: now, lastModificationTime: now, lastAccessTime: now,
                                 expiryTime: package.entry.times?.expiryTime, expires: package.entry.times?.expires ?? false,
                                 usageCount: 0, locationChanged: now)
        for file in package.attachments {
            let index = poolIndex(for: file.data)
            entry.binaries.append(KDBX.ProtectedBinary(key: file.name, value: .ref(UInt32(index))))
        }
        addEntry(entry, to: groupID)
        if let icon = package.icon { setCustomIcon(icon, for: entry.uuid) }
        return entry.uuid
    }
}

// MARK: - Exportar

public extension Vault {
    /// CSV con las mismas columnas que KeePassXC. Ojo: va sin cifrar.
    func csv(only ids: Set<UUID>? = nil) -> String {
        var lines = ["\"Group\",\"Title\",\"Username\",\"Password\",\"URL\",\"Notes\",\"TOTP\",\"Icon\",\"Last Modified\",\"Created\""]
        let iso = ISO8601DateFormatter()
        func walk(_ group: KDBX.Group, path: [String]) {
            guard !excludedFromBrowsing.contains(group.uuid) else { return }
            let here = path + [group.displayName]
            for entry in group.entries where ids?.contains(entry.uuid) ?? true {
                let fields = [here.joined(separator: "/"), entry.title, entry.userName, entry.string(FieldKey.password), entry.url, entry.notes,
                              entry.string(FieldKey.otp), String(entry.iconID),
                              entry.times?.lastModificationTime.map(iso.string) ?? "", entry.times?.creationTime.map(iso.string) ?? ""]
                lines.append(fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
            }
            for child in group.groups { walk(child, path: here) }
        }
        walk(root, path: [])
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Filtraciones (Have I Been Pwned)

/// Comprueba si una contraseña ha salido en filtraciones sin enviarla: solo viajan los 5 primeros
/// caracteres de su huella SHA-1 y la comparación se hace en el Mac (k-anonimato).
public enum PwnedPasswords {
    public static func sha1(_ password: String) -> String {
        Insecure.SHA1.hash(data: Data(password.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    /// Busca el resto de la huella en la respuesta del servicio. Devuelve cuántas veces ha aparecido.
    public static func count(in response: String, suffix: String) -> Int {
        for line in response.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":")
            guard parts.count == 2, parts[0].uppercased() == suffix else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    public static func check(sha1 hash: String) async throws -> Int {
        let prefix = String(hash.prefix(5)), suffix = String(hash.dropFirst(5))
        var request = URLRequest(url: URL(string: "https://api.pwnedpasswords.com/range/\(prefix)")!)
        // El relleno hace que todas las respuestas pesen parecido y no se pueda adivinar nada por el tamaño.
        request.setValue("true", forHTTPHeaderField: "Add-Padding")
        #if os(iOS)
        request.setValue("Boveda-iOS", forHTTPHeaderField: "User-Agent")
        #else
        request.setValue("Boveda-macOS", forHTTPHeaderField: "User-Agent")
        #endif
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return count(in: String(decoding: data, as: UTF8.self), suffix: suffix)
    }
}

// MARK: - Contraseñas parecidas

enum Similarity {
    /// La parte "de letras" de una contraseña: "Madrid2023!" y "madrid2024" dan "madrid".
    static func core(_ password: String) -> String {
        String(password.lowercased().filter(\.isLetter))
    }

    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Lo que se compara de cada contraseña, calculado una sola vez (la auditoría compara todas con todas).
    struct Prepared {
        let raw: String
        let core: String
        let chars: [Character]
        init(_ password: String) {
            raw = password
            core = Similarity.core(password)
            chars = Array(password.lowercased())
        }
    }

    static func similar(_ a: String, _ b: String) -> Bool { similar(Prepared(a), Prepared(b)) }

    static func similar(_ a: Prepared, _ b: Prepared) -> Bool {
        guard a.raw != b.raw else { return false }
        if a.core.count >= 4, a.core == b.core { return true }
        let x = a.chars, y = b.chars
        let longest = max(x.count, y.count)
        guard min(x.count, y.count) >= 6, abs(x.count - y.count) <= longest / 5 else { return false }
        return Double(distance(x, y)) / Double(longest) <= 0.25
    }
}

// MARK: - Contraseñas comunes

enum CommonPasswords {
    static let list: Set<String> = [
        "123456", "123456789", "12345678", "12345", "1234567", "1234567890", "111111", "000000", "123123", "654321",
        "password", "password1", "password123", "qwerty", "qwerty123", "qwertyuiop", "abc123", "iloveyou", "admin", "admin123",
        "welcome", "letmein", "monkey", "dragon", "football", "baseball", "sunshine", "princess", "master", "shadow",
        "superman", "batman", "trustno1", "starwars", "michael", "jennifer", "computer", "whatever", "freedom", "hello",
        "contraseña", "contrasena", "contraseña1", "contrasena1", "123456a", "a123456", "tequiero", "teamo", "barcelona", "realmadrid",
        "madrid", "españa", "espana", "futbol", "fútbol", "hola", "hola123", "holamundo", "amor", "corazon",
        "princesa", "estrella", "mariposa", "secreto", "bonita", "carlos", "alejandro", "daniel", "david", "maria",
        "1q2w3e4r", "1qaz2wsx", "zaq12wsx", "asdfgh", "asdfghjkl", "zxcvbnm", "passw0rd", "p@ssw0rd", "changeme", "default",
        "666666", "888888", "121212", "112233", "159753", "987654321", "123321", "qwe123", "test", "test123",
    ]

    static func contains(_ password: String) -> Bool {
        list.contains(password.lowercased())
    }
}

// MARK: - Sitios con 2FA

public enum TwoFactorSites {
    /// Dominio que se busca en la lista: el de la web y sus dominios padre ("login.bbva.es" → "bbva.es").
    public static func candidates(for urlText: String) -> [String] {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
              var host = url.host()?.lowercased(), host.contains(".") else { return [] }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var parts = host.split(separator: ".").map(String.init)
        var result: [String] = []
        while parts.count >= 2 {
            result.append(parts.joined(separator: "."))
            parts.removeFirst()
        }
        return result
    }

    /// Lee la lista pública de 2fa.directory (formato v3: [[nombre, {domain, tfa: [...]}], …]).
    public static func parse(_ data: Data) -> Set<String> {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        var domains = Set<String>()
        for item in array {
            guard let pair = item as? [Any], pair.count == 2, let info = pair[1] as? [String: Any] else { continue }
            let methods = info["tfa"] as? [String] ?? []
            guard methods.contains("totp") else { continue }
            if let domain = info["domain"] as? String { domains.insert(domain.lowercased()) }
            for extra in info["additional-domains"] as? [String] ?? [] { domains.insert(extra.lowercased()) }
        }
        return domains
    }
}
