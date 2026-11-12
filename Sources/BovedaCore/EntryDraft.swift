import Foundation
import KDBXKit

/// Copia editable de una entrada mientras está abierto el editor.
public struct EntryDraft: Identifiable {
    public var id: UUID { original.uuid }
    public let original: KDBX.Entry
    public var groupID: UUID
    public let isNew: Bool

    public var title: String
    public var userName: String
    public var password: String
    public var url: String
    public var notes: String
    public var otp: String
    public var tags: String
    public var expires: Bool
    public var expiryDate: Date
    public var customFields: [CustomField]
    public var kind: EntryKind
    /// Datos de la tarjeta (número, titular, caducidad, CVV, PIN).
    public var card: [String: String]

    public struct CustomField: Identifiable, Equatable {
        public let id = UUID()
        public var key: String
        public var value: String
        public var protected: Bool

        public init(key: String, value: String, protected: Bool) {
            self.key = key
            self.value = value
            self.protected = protected
        }
    }

    public init(entry: KDBX.Entry, groupID: UUID, isNew: Bool) {
        original = entry
        self.groupID = groupID
        self.isNew = isNew
        title = entry.title
        userName = entry.userName
        password = entry.string(FieldKey.password)
        url = entry.url
        notes = entry.notes
        otp = entry.string(FieldKey.otp)
        tags = entry.tags.filter { $0 != favoriteTag }.joined(separator: ", ")
        expires = entry.times?.expires ?? false
        expiryDate = entry.times?.expiryTime ?? Calendar.current.date(byAdding: .month, value: 6, to: Date())!
        kind = entry.kind
        card = [:]
        for key in CardField.all { card[key] = entry.string(key) }
        let hidden: Set<String> = entry.kind == .card ? Set(CardField.all) : []
        customFields = entry.customFields.filter { !hidden.contains($0.key) }
            .map { CustomField(key: $0.key, value: $0.value.revealedString, protected: entry.isProtected($0.key)) }
    }

    public var otpIsValid: Bool { otp.trimmingCharacters(in: .whitespaces).isEmpty || TOTP.parse(otp) != nil }

    public var customKeysAreValid: Bool {
        let keys = customFields.map { $0.key.trimmingCharacters(in: .whitespaces) }
        let reserved = FieldKey.standard.union(TOTP.fieldKeys).union(kind == .card ? Set(CardField.all) : [])
        return !keys.contains("") && Set(keys).count == keys.count && keys.allSatisfy { !reserved.contains($0) }
    }

    public func apply(to base: KDBX.Entry) -> KDBX.Entry {
        var entry = base
        entry.set(FieldKey.title, title.trimmingCharacters(in: .whitespaces).isEmpty ? "Sin título" : title)
        entry.set(FieldKey.userName, userName)
        entry.set(FieldKey.password, password, protected: true)
        entry.set(FieldKey.url, url.trimmingCharacters(in: .whitespaces))
        entry.set(FieldKey.notes, notes)

        let otpText = otp.trimmingCharacters(in: .whitespacesAndNewlines)
        if otpText != entry.string(FieldKey.otp) {
            if otpText.isEmpty {
                entry.remove(FieldKey.otp)
            } else {
                // Si nos pegan solo la clave, la guardamos como enlace estándar para que KeePassium la lea igual.
                let normalized = otpText.lowercased().hasPrefix("otpauth://") ? otpText
                    : "otpauth://totp/\(Self.percent(title)):\(Self.percent(userName))?secret=\(otpText.uppercased().filter { $0 != " " })&period=30&digits=6&issuer=\(Self.percent(title))"
                entry.set(FieldKey.otp, normalized, protected: true)
            }
            // Quitamos formatos antiguos para que no haya dos códigos distintos.
            for key in TOTP.fieldKeys where key != FieldKey.otp { entry.remove(key) }
        }

        var keep = Set(customFields.map { $0.key.trimmingCharacters(in: .whitespaces) })
        if kind == .card {
            for key in CardField.all {
                let value = (card[key] ?? "").trimmingCharacters(in: .whitespaces)
                if value.isEmpty { continue }
                keep.insert(key)
                entry.set(key, value, protected: CardField.secret.contains(key))
            }
        }
        for field in entry.customFields where !keep.contains(field.key) { entry.remove(field.key) }
        for field in customFields { entry.set(field.key.trimmingCharacters(in: .whitespaces), field.value, protected: field.protected) }
        entry.setKind(kind)

        let newTags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        entry.tags = (base.isFavorite ? [favoriteTag] : []) + newTags

        var times = entry.times ?? KDBX.Times()
        times.expires = expires
        times.expiryTime = expires ? expiryDate : times.expiryTime
        entry.times = times
        return entry
    }

    private static func percent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: ":?&="))) ?? ""
    }
}
