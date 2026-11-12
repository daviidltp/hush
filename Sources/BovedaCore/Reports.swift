import Foundation
import KDBXKit

/// Informe de salud de las contraseñas, como el de KeePassXC/Strongbox.
public struct PasswordReport {
    public struct Item: Identifiable {
        public var id: UUID { entry.uuid }
        public let entry: KDBX.Entry
        public let detail: String
    }

    public var weak: [Item] = []
    public var reused: [Item] = []
    public var empty: [Item] = []
    public var expired: [Item] = []

    public var issueCount: Int { weak.count + reused.count + empty.count + expired.count }

    public init(entries: [KDBX.Entry]) {
        var byPassword: [String: [KDBX.Entry]] = [:]
        for entry in entries where !entry.excludedFromAudit && entry.kind == .login {
            let password = entry.string(FieldKey.password)
            if password.isEmpty {
                empty.append(Item(entry: entry, detail: L("Sin contraseña")))
            } else {
                byPassword[password, default: []].append(entry)
                let strength = PasswordStrength.of(password)
                if strength < .fair { weak.append(Item(entry: entry, detail: strength.label)) }
            }
            if entry.isExpired { expired.append(Item(entry: entry, detail: L("Caducada"))) }
        }
        for (_, group) in byPassword where group.count > 1 {
            for entry in group { reused.append(Item(entry: entry, detail: L("Repetida en \(group.count) entradas"))) }
        }
        reused.sort { $0.entry.title.localizedStandardCompare($1.entry.title) == .orderedAscending }
    }
}

public extension Vault {
    /// Ordena alfabéticamente los subgrupos de todos los niveles (⌘↓ / ⌘↑ en KeePassXC).
    mutating func sortGroups(ascending: Bool) {
        func sort(_ group: inout KDBX.Group) {
            group.groups.sort {
                let order = $0.displayName.localizedStandardCompare($1.displayName)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            for index in group.groups.indices { sort(&group.groups[index]) }
        }
        sort(&root)
    }

    /// Todas las etiquetas usadas, sin la de favoritos.
    var allTags: [String] {
        let tags = root.allEntries(excluding: excludedFromBrowsing).flatMap(\.tags).filter { $0 != favoriteTag }
        return Array(Set(tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Auditoría por entrada, como la de Strongbox: filtradas, repetidas, parecidas, débiles, caducadas y sin 2FA.
/// Las entradas marcadas como "excluir de la auditoría" no se revisan.
public struct Audit: @unchecked Sendable {
    /// Para cada entrada con la contraseña repetida, en cuántas entradas aparece.
    public private(set) var duplicates: [UUID: Int] = [:]
    public private(set) var weak: [UUID: PasswordStrength] = [:]
    public private(set) var short: Set<UUID> = []
    public private(set) var common: Set<UUID> = []
    /// Entradas con una contraseña parecida a la de otras (cuántas).
    public private(set) var similar: [UUID: Int] = [:]
    /// Veces que la contraseña ha aparecido en filtraciones.
    public private(set) var pwned: [UUID: Int] = [:]
    public private(set) var expired: Set<UUID> = []
    /// La web permite 2FA y la entrada no lo tiene.
    public private(set) var missing2FA: Set<UUID> = []
    /// Con demasiadas contraseñas distintas no se buscan las parecidas (sería muy lento).
    public private(set) var similarSkipped = false
    public static let similarLimit = 1500

    public static let minimumLength = 8

    /// Débiles en sentido amplio: poca fuerza, cortas o de las más usadas.
    public var allWeak: Set<UUID> { Set(weak.keys).union(short).union(common) }

    public var all: Set<UUID> {
        allWeak.union(duplicates.keys).union(similar.keys).union(pwned.keys).union(expired).union(missing2FA)
    }

    /// - Parameters:
    ///   - pwnedCount: veces que una contraseña ha salido en filtraciones (nil si aún no se sabe).
    ///   - twoFactorDomains: dominios que ofrecen códigos 2FA.
    public init(entries: [KDBX.Entry], pwnedCount: (String) -> Int? = { _ in nil }, twoFactorDomains: Set<String> = []) {
        var byPassword: [String: [UUID]] = [:]
        for entry in entries where !entry.excludedFromAudit {
            if entry.isExpired { expired.insert(entry.uuid) }
            guard entry.kind == .login else { continue }
            let password = entry.string(FieldKey.password)
            if !twoFactorDomains.isEmpty, TOTP.from(entry) == nil, !entry.hasPasskey,
               TwoFactorSites.candidates(for: entry.url).contains(where: twoFactorDomains.contains) {
                missing2FA.insert(entry.uuid)
            }
            guard !password.isEmpty else { continue }
            byPassword[password, default: []].append(entry.uuid)
            let strength = PasswordStrength.of(password)
            if strength < .fair { weak[entry.uuid] = strength }
            if password.count < Self.minimumLength { short.insert(entry.uuid) }
            if CommonPasswords.contains(password) { common.insert(entry.uuid) }
            if let count = pwnedCount(password), count > 0 { pwned[entry.uuid] = count }
        }
        for (_, ids) in byPassword where ids.count > 1 {
            for id in ids { duplicates[id] = ids.count }
        }
        // Parecidas: se compara cada contraseña distinta con las demás (con un límite para bases enormes).
        let distinct = Array(byPassword.keys)
        similarSkipped = distinct.count > Self.similarLimit
        if !similarSkipped {
            var related: [String: Set<String>] = [:]
            let prepared = distinct.map(Similarity.Prepared.init)
            for i in prepared.indices {
                for j in prepared.indices where j > i && Similarity.similar(prepared[i], prepared[j]) {
                    related[distinct[i], default: []].insert(distinct[j])
                    related[distinct[j], default: []].insert(distinct[i])
                }
            }
            for (password, others) in related {
                let count = others.reduce(0) { $0 + (byPassword[$1]?.count ?? 0) }
                for id in byPassword[password] ?? [] { similar[id] = count }
            }
        }
    }

    /// Problemas de una entrada, en frases cortas.
    public func issues(for id: UUID) -> [String] {
        var list: [String] = []
        if let count = pwned[id] {
            list.append(L("Ha aparecido en filtraciones \(count.formatted(.number.locale(appLocale))) veces: cámbiala"))
        }
        if let count = duplicates[id] { list.append(L("Contraseña repetida en \(count) entradas")) }
        if let count = similar[id] { list.append(count == 1 ? L("Contraseña parecida a la de otra entrada") : L("Contraseña parecida a la de otras \(count) entradas")) }
        if common.contains(id) { list.append(L("Es una de las contraseñas más usadas")) }
        if let strength = weak[id] { list.append(L("Contraseña \(strength.label.lowercased())")) }
        if short.contains(id) { list.append(L("Contraseña corta: menos de \(Self.minimumLength) caracteres")) }
        if expired.contains(id) { list.append(L("Caducada")) }
        if missing2FA.contains(id) { list.append(L("Esta web permite 2FA y esta entrada no guarda ningún código")) }
        return list
    }
}

public extension KDBX.Entry {
    /// Entradas con clave de acceso (passkey).
    var hasPasskey: Bool { strings.contains { $0.key.hasPrefix("KPEX_PASSKEY") } }
}
