import Foundation
import KDBXKit

/// Un archivo adjunto a una entrada (como en KeePassXC, KeePassium y Strongbox).
public struct Attachment: Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let size: Int
}

public extension KDBX.Entry {
    var hasAttachments: Bool { !binaries.isEmpty }
}

public extension Vault {
    func attachments(of entry: KDBX.Entry) -> [Attachment] {
        entry.binaries.map { Attachment(name: $0.key, size: data(of: $0)?.count ?? 0) }
    }

    func attachmentData(named name: String, in entry: KDBX.Entry) -> Data? {
        entry.binaries.first { $0.key == name }.flatMap(data(of:))
    }

    private func data(of binary: KDBX.ProtectedBinary) -> Data? {
        switch binary.value {
        case let .inline(data, _): return data
        case let .ref(index):
            let pool = content.innerHeader.binaryContent
            return pool.indices.contains(Int(index)) ? pool[Int(index)].data : nil
        }
    }

    /// Añade un adjunto (guarda la versión anterior de la entrada en el historial). Devuelve el nombre final.
    @discardableResult
    mutating func addAttachment(named name: String, data: Data, to entryID: UUID) -> String {
        guard let entry = locate(entryID)?.entry else { return name }
        let finalName = Self.uniqueName(name, taken: Set(entry.binaries.map(\.key)))
        let index = poolIndex(for: data)
        updateEntry(entryID) { $0.binaries.append(KDBX.ProtectedBinary(key: finalName, value: .ref(UInt32(index)))) }
        return finalName
    }

    /// Posición del contenido en el archivo. Si el mismo contenido ya está guardado, se reutiliza en vez de duplicarlo.
    mutating func poolIndex(for data: Data) -> Int {
        let pool = content.innerHeader.binaryContent
        if let existing = pool.firstIndex(where: { $0.data == data }) { return existing }
        content.innerHeader.binaryContent.append(InnerHeader.BinaryContent(shouldBeProtected: true, data: data))
        return pool.count
    }

    /// Quita un adjunto. La versión anterior queda en el historial, como hace KeePass.
    mutating func removeAttachment(named name: String, from entryID: UUID) {
        updateEntry(entryID) { $0.binaries.removeAll { $0.key == name } }
        compactAttachments()
    }

    mutating func renameAttachment(_ name: String, to newName: String, in entryID: UUID) {
        guard let entry = locate(entryID)?.entry, name != newName else { return }
        let finalName = Self.uniqueName(newName, taken: Set(entry.binaries.map(\.key)).subtracting([name]))
        updateEntry(entryID) { entry in
            entry.binaries = entry.binaries.map { $0.key == name ? KDBX.ProtectedBinary(key: finalName, value: $0.value) : $0 }
        }
    }

    /// Quita del archivo los adjuntos que ya no usa ninguna entrada ni ningún historial.
    mutating func compactAttachments() {
        var used: [UInt32] = []
        func collect(_ entry: KDBX.Entry) {
            for binary in entry.binaries { if case let .ref(index) = binary.value, !used.contains(index) { used.append(index) } }
            entry.history.forEach(collect)
        }
        func walk(_ group: KDBX.Group) {
            group.entries.forEach(collect)
            group.groups.forEach(walk)
        }
        walk(root)
        let pool = content.innerHeader.binaryContent
        guard used.count < pool.count else { return }
        used.sort()
        var map: [UInt32: UInt32] = [:]
        var newPool: [InnerHeader.BinaryContent] = []
        for old in used where pool.indices.contains(Int(old)) {
            map[old] = UInt32(newPool.count)
            newPool.append(pool[Int(old)])
        }
        func remap(_ entry: inout KDBX.Entry) {
            entry.binaries = entry.binaries.map { binary in
                guard case let .ref(index) = binary.value, let mapped = map[index] else { return binary }
                return KDBX.ProtectedBinary(key: binary.key, value: .ref(mapped))
            }
            for index in entry.history.indices { remap(&entry.history[index]) }
        }
        func remapGroup(_ group: inout KDBX.Group) {
            for index in group.entries.indices { remap(&group.entries[index]) }
            for index in group.groups.indices { remapGroup(&group.groups[index]) }
        }
        var tree = root
        remapGroup(&tree)
        root = tree
        content.innerHeader.binaryContent = newPool
    }

    private static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }
}
