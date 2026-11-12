import Foundation
import KDBXKit

public extension KDBX.Entry {
    func string(_ key: String) -> String {
        strings.first { $0.key == key }?.value.revealedString ?? ""
    }

    func isProtected(_ key: String) -> Bool {
        guard let value = strings.first(where: { $0.key == key })?.value else { return false }
        switch value {
        case .regular: return false
        case .unprotected, .lazyInnerCipher, .protectedInMemory: return true
        }
    }

    var title: String { string(FieldKey.title) }
    var userName: String { string(FieldKey.userName) }
    var url: String { string(FieldKey.url) }
    var notes: String { string(FieldKey.notes) }
    var isFavorite: Bool { tags.contains(favoriteTag) }
    var modified: Date? { times?.lastModificationTime }
    var isExpired: Bool {
        guard times?.expires == true, let date = times?.expiryTime else { return false }
        return date < Date()
    }

    /// Campos que no son los cinco estándar ni el de 2FA.
    var customFields: [KDBX.ProtectedString] {
        strings.filter { !FieldKey.standard.contains($0.key) && !TOTP.fieldKeys.contains($0.key) }
    }

    mutating func set(_ key: String, _ value: String, protected: Bool? = nil) {
        let shouldProtect = protected ?? (key == FieldKey.password || isProtected(key))
        // En KDBXKit, `.unprotected` es "protegido, ya descifrado": al guardar lo cifra con Protected="True".
        let newValue: KDBX.ProtectedString.Value = shouldProtect ? .unprotected(value) : .regular(value)
        if let index = strings.firstIndex(where: { $0.key == key }) {
            strings[index].value = newValue
        } else {
            strings.append(KDBX.ProtectedString(key: key, value: newValue))
        }
    }

    mutating func remove(_ key: String) {
        strings.removeAll { $0.key == key }
    }

    static func make(title: String) -> KDBX.Entry {
        let now = Date()
        var entry = KDBX.Entry(uuid: UUID(), times: KDBX.Times(creationTime: now, lastModificationTime: now, lastAccessTime: now, expires: false, usageCount: 0, locationChanged: now))
        entry.set(FieldKey.title, title)
        entry.set(FieldKey.userName, "")
        entry.set(FieldKey.password, "", protected: true)
        entry.set(FieldKey.url, "")
        entry.set(FieldKey.notes, "")
        return entry
    }
}

/// Resultado de buscar una entrada: la entrada y la ruta de grupos hasta ella.
public struct LocatedEntry {
    public let entry: KDBX.Entry
    public let groupPath: [KDBX.Group]
    public var group: KDBX.Group { groupPath.last! }
}

public extension KDBX.Group {
    var displayName: String { name ?? L("Sin nombre") }

    /// Todas las entradas de este grupo y sus subgrupos, saltándose los grupos indicados.
    func allEntries(excluding excluded: Set<UUID> = []) -> [KDBX.Entry] {
        guard !excluded.contains(uuid) else { return [] }
        return entries + groups.flatMap { $0.allEntries(excluding: excluded) }
    }

    func entryCount(excluding excluded: Set<UUID> = []) -> Int {
        allEntries(excluding: excluded).count
    }

    func group(_ id: UUID) -> KDBX.Group? {
        if uuid == id { return self }
        for child in groups { if let found = child.group(id) { return found } }
        return nil
    }

    func locate(_ entryID: UUID, path: [KDBX.Group] = []) -> LocatedEntry? {
        let here = path + [self]
        if let entry = entries.first(where: { $0.uuid == entryID }) {
            return LocatedEntry(entry: entry, groupPath: here)
        }
        for child in groups { if let found = child.locate(entryID, path: here) { return found } }
        return nil
    }

    /// Lista plana de grupos con su nivel, para selectores.
    func flattened(level: Int = 0, excluding excluded: Set<UUID> = []) -> [(group: KDBX.Group, level: Int)] {
        guard !excluded.contains(uuid) else { return [] }
        return [(self, level)] + groups.flatMap { $0.flattened(level: level + 1, excluding: excluded) }
    }

    @discardableResult
    mutating func mutateGroup(_ id: UUID, _ body: (inout KDBX.Group) -> Void) -> Bool {
        if uuid == id { body(&self); return true }
        for index in groups.indices where groups[index].mutateGroup(id, body) { return true }
        return false
    }

    @discardableResult
    mutating func mutateEntry(_ id: UUID, _ body: (inout KDBX.Entry) -> Void) -> Bool {
        if let index = entries.firstIndex(where: { $0.uuid == id }) { body(&entries[index]); return true }
        for index in groups.indices where groups[index].mutateEntry(id, body) { return true }
        return false
    }

    mutating func removeEntry(_ id: UUID) -> KDBX.Entry? {
        if let index = entries.firstIndex(where: { $0.uuid == id }) { return entries.remove(at: index) }
        for index in groups.indices { if let removed = groups[index].removeEntry(id) { return removed } }
        return nil
    }

    mutating func removeGroup(_ id: UUID) -> KDBX.Group? {
        if let index = groups.firstIndex(where: { $0.uuid == id }) { return groups.remove(at: index) }
        for index in groups.indices { if let removed = groups[index].removeGroup(id) { return removed } }
        return nil
    }

    static func make(name: String, iconID: UInt32 = 48) -> KDBX.Group {
        let now = Date()
        return KDBX.Group(
            uuid: UUID(), name: name, notes: "", iconID: iconID,
            times: KDBX.Times(creationTime: now, lastModificationTime: now, lastAccessTime: now, expires: false, usageCount: 0, locationChanged: now)
        )
    }
}

public extension Vault {
    /// Límite de versiones del historial según la base de datos (nil = ilimitado). KeePass usa 10 por defecto.
    var historyLimit: Int? {
        switch content.database.meta.historyMaxItems {
        case .unlimited: return nil
        case let .value(n): return Int(n)
        case nil: return 10
        }
    }

    var excludedFromBrowsing: Set<UUID> {
        recycleBinUUID.map { [$0] } ?? []
    }

    func locate(_ entryID: UUID) -> LocatedEntry? { root.locate(entryID) }

    func isInRecycleBin(_ entryID: UUID) -> Bool {
        guard let bin = recycleBinUUID, let located = locate(entryID) else { return false }
        return located.groupPath.contains { $0.uuid == bin }
    }

    /// Aplica un cambio a una entrada guardando la versión anterior en su historial.
    mutating func updateEntry(_ id: UUID, _ body: (inout KDBX.Entry) -> Void) {
        let limit = historyLimit
        root.mutateEntry(id) { entry in
            var snapshot = entry
            snapshot.history = []
            body(&entry)
            guard entry != { var e = snapshot; e.history = entry.history; return e }() else { return }
            entry.history.append(snapshot)
            if let limit, entry.history.count > limit {
                entry.history.removeFirst(entry.history.count - limit)
            }
            let now = Date()
            entry.times = entry.times ?? KDBX.Times()
            entry.times?.lastModificationTime = now
            entry.times?.lastAccessTime = now
        }
    }

    /// Marca o desmarca favorito sin ensuciar el historial.
    mutating func toggleFavorite(_ id: UUID) {
        root.mutateEntry(id) { entry in
            if entry.isFavorite { entry.tags.removeAll { $0 == favoriteTag } } else { entry.tags.append(favoriteTag) }
            entry.times?.lastModificationTime = Date()
        }
    }

    mutating func addEntry(_ entry: KDBX.Entry, to groupID: UUID) {
        root.mutateGroup(groupID) { $0.entries.append(entry) }
    }

    mutating func addGroup(named name: String, to parentID: UUID) -> UUID {
        let group = KDBX.Group.make(name: name)
        root.mutateGroup(parentID) { $0.groups.append(group) }
        return group.uuid
    }

    mutating func renameGroup(_ id: UUID, to name: String) {
        root.mutateGroup(id) { group in
            group.name = name
            group.times?.lastModificationTime = Date()
        }
    }

    mutating func moveEntry(_ id: UUID, to groupID: UUID) {
        let previous = locate(id)?.group.uuid
        guard root.group(groupID) != nil, previous != groupID, var entry = root.removeEntry(id) else { return }
        entry.previousParentGroup = previous
        entry.times?.locationChanged = Date()
        root.mutateGroup(groupID) { $0.entries.append(entry) }
    }

    /// Si la base tiene la papelera desactivada, lo borrado se elimina directamente.
    var usesRecycleBin: Bool { content.database.meta.recycleBinEnabled ?? true }

    /// Borra un grupo: lo mueve a la papelera, o lo elimina si ya estaba dentro (o si no hay papelera).
    mutating func deleteGroup(_ id: UUID) {
        guard id != root.uuid, id != recycleBinUUID else { return }
        let insideBin = recycleBinUUID.flatMap { root.group($0)?.group(id) } != nil
        if !usesRecycleBin || insideBin {
            guard let group = root.removeGroup(id) else { return }
            let now = Date()
            let removed = group.allEntries().map(\.uuid) + group.flattened().map(\.group.uuid)
            content.database.root.deletedObjects += removed.map { KDBX.DeletedObject(uuid: $0, deletionTime: now) }
            return
        }
        let parent = parentOfGroup(id)
        let bin = ensureRecycleBin()
        guard var group = root.removeGroup(id) else { return }
        group.previousParentGroup = parent
        group.times?.locationChanged = Date()
        root.mutateGroup(bin) { $0.groups.append(group) }
    }

    private func parentOfGroup(_ id: UUID) -> UUID? {
        root.flattened().first { $0.group.groups.contains { $0.uuid == id } }?.group.uuid
    }

    /// Si un grupo está dentro de la papelera (sin contar la papelera misma).
    func isGroupInRecycleBin(_ id: UUID) -> Bool {
        guard let bin = recycleBinUUID, bin != id else { return false }
        return root.group(bin)?.group(id) != nil
    }

    /// Saca de la papelera una entrada o un grupo y lo devuelve a su grupo de antes
    /// (o a la raíz si ese grupo ya no existe o también está en la papelera).
    mutating func restoreFromRecycleBin(_ id: UUID) {
        func destination(_ previous: UUID?) -> UUID {
            if let previous, root.group(previous) != nil, previous != recycleBinUUID, !isGroupInRecycleBin(previous) { return previous }
            return root.uuid
        }
        if isInRecycleBin(id), let entry = locate(id)?.entry {
            moveEntry(id, to: destination(entry.previousParentGroup))
        } else if isGroupInRecycleBin(id), let previous = root.group(id).map({ $0.previousParentGroup }) {
            let target = destination(previous)
            guard var group = root.removeGroup(id) else { return }
            group.previousParentGroup = nil
            group.times?.locationChanged = Date()
            root.mutateGroup(target) { $0.groups.append(group) }
        }
    }

    /// Papelera de reciclaje como hacen KeePassXC y KeePassium: la crea si no existe.
    mutating func ensureRecycleBin() -> UUID {
        if let bin = recycleBinUUID, root.group(bin) != nil { return bin }
        let id = addGroup(named: L("Papelera"), to: root.uuid)
        root.mutateGroup(id) { $0.iconID = 43 }
        content.database.meta.recycleBinUUID = id
        return id
    }

    /// Borra una entrada: primero a la papelera; si ya está en la papelera, la elimina del todo.
    mutating func deleteEntry(_ id: UUID) {
        if isInRecycleBin(id) || !usesRecycleBin {
            guard root.removeEntry(id) != nil else { return }
            content.database.root.deletedObjects.append(KDBX.DeletedObject(uuid: id, deletionTime: Date()))
            return
        }
        let parent = locate(id)?.group.uuid
        let bin = ensureRecycleBin()
        guard var entry = root.removeEntry(id) else { return }
        entry.previousParentGroup = parent
        entry.times?.locationChanged = Date()
        root.mutateGroup(bin) { $0.entries.append(entry) }
    }

    mutating func emptyRecycleBin() {
        guard let bin = recycleBinUUID, let group = root.group(bin) else { return }
        let now = Date()
        let removed = group.allEntries().map(\.uuid) + group.flattened().dropFirst().map(\.group.uuid)
        content.database.root.deletedObjects += removed.map { KDBX.DeletedObject(uuid: $0, deletionTime: now) }
        root.mutateGroup(bin) { group in
            group.entries = []
            group.groups = []
        }
    }
}
