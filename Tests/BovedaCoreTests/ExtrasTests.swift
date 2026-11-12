import Foundation
import KDBXKit
import Testing
@testable import BovedaCore

@Suite struct ExtrasTests {
    @Test func passphraseUsesWordlist() {
        var options = GeneratorOptions()
        options.usePassphrase = true
        options.wordCount = 4
        options.separator = "-"
        options.addNumber = true
        let phrase = PasswordGenerator.generate(options)
        let parts = phrase.split(separator: "-")
        #expect(parts.count == 5)
        #expect(SpanishWords.list.count == 8192)
        #expect(EnglishWords.list.count == 7776)
        // La lista depende del idioma de la app (español o la inglesa de la EFF).
        let words = Set(PasswordGenerator.passphraseWords)
        #expect(parts.prefix(4).allSatisfy { words.contains($0.lowercased()) && $0.first!.isUppercase })
        #expect(Int(parts.last!) != nil)
        #expect(PasswordGenerator.entropy(options) > 58)
    }

    @Test func oldGeneratorSettingsStillDecode() throws {
        let old = #"{"length":30,"uppercase":true,"lowercase":true,"digits":false,"symbols":true,"avoidAmbiguous":true,"requireEachGroup":true}"#
        let options = try JSONDecoder().decode(GeneratorOptions.self, from: Data(old.utf8))
        #expect(options.length == 30 && !options.digits && !options.usePassphrase && options.wordCount == 5)
    }

    @Test func referencesResolve() throws {
        let dir = try VaultTests.tempDir()
        var vault = try VaultTests.makeVault(in: dir)
        let source = try #require(vault.root.entries.first)
        var other = KDBX.Entry.make(title: "Copia")
        other.set(FieldKey.password, FieldReference.make(field: "P", to: source), protected: true)
        other.set(FieldKey.userName, "{REF:U@T:GitHub}")
        vault.addEntry(other, to: vault.root.uuid)
        #expect(vault.resolve(other.string(FieldKey.password)) == "s3creta")
        #expect(vault.resolve(other.userName) == "david")
        #expect(vault.resolve("sin referencias") == "sin referencias")
        #expect(vault.resolve("{REF:P@I:00000000000000000000000000000000}") == "{REF:P@I:00000000000000000000000000000000}")
    }

    @Test func restoreGroupAndEntryFromRecycleBin() throws {
        let dir = try VaultTests.tempDir()
        var vault = try VaultTests.makeVault(in: dir)
        let entryID = try #require(vault.root.entries.first?.uuid)
        let work = vault.addGroup(named: "Trabajo", to: vault.root.uuid)
        let inner = vault.addGroup(named: "Proyectos", to: work)
        vault.moveEntry(entryID, to: inner)
        vault.deleteGroup(inner)
        #expect(vault.isGroupInRecycleBin(inner) && vault.isInRecycleBin(entryID))
        vault.restoreFromRecycleBin(inner)
        #expect(!vault.isGroupInRecycleBin(inner) && vault.root.group(work)?.group(inner) != nil)
        #expect(!vault.isInRecycleBin(entryID))
        // Una entrada vuelve a su grupo; si ese grupo ya no está, a la raíz.
        vault.deleteEntry(entryID)
        vault.restoreFromRecycleBin(entryID)
        #expect(vault.locate(entryID)?.group.uuid == inner)
        // Se puede guardar y reabrir sin problemas.
        try vault.serialized().write(to: vault.url)
        _ = try Vault.open(url: vault.url, unlock: vault.unlock)
    }

    @Test func historyDiffSeesExpiryOnlyChanges() throws {
        let dir = try VaultTests.tempDir()
        var vault = try VaultTests.makeVault(in: dir)
        let id = try #require(vault.root.entries.first?.uuid)
        vault.updateEntry(id) { $0.times?.expires = true; $0.times?.expiryTime = Date(timeIntervalSince1970: 1_800_000_000) }
        let entry = try #require(vault.locate(id)?.entry)
        let changes = entry.history[0].changes(to: entry)
        #expect(changes.map(\.label) == ["Caducidad"])
        #expect(changes[0].old == "Nunca")
    }

    @Test func historyDiffAndRestore() throws {
        let dir = try VaultTests.tempDir()
        var vault = try VaultTests.makeVault(in: dir)
        let id = try #require(vault.root.entries.first?.uuid)
        vault.updateEntry(id) { $0.set(FieldKey.password, "otra"); $0.set(FieldKey.url, "github.com") }
        var entry = try #require(vault.locate(id)?.entry)
        let changes = entry.history[0].changes(to: entry)
        #expect(changes.map(\.label) == ["Contraseña", "Web"])
        #expect(changes[0].secret && changes[0].old == "s3creta" && changes[0].new == "otra")

        vault.restoreHistory(0, of: id)
        entry = try #require(vault.locate(id)?.entry)
        #expect(entry.string(FieldKey.password) == "s3creta" && entry.url.isEmpty)
        // La versión que se ha deshecho queda guardada.
        #expect(entry.history.count == 2 && entry.history[1].string(FieldKey.password) == "otra")
        try vault.save(backups: BackupStore(directory: dir.appendingPathComponent("copias")))
    }

    @Test func passwordChangedDateIgnoresOtherEdits() {
        var entry = KDBX.Entry.make(title: "X")
        let t0 = Date(timeIntervalSince1970: 1_000_000), t1 = Date(timeIntervalSince1970: 2_000_000), t2 = Date(timeIntervalSince1970: 3_000_000)
        var v0 = entry; v0.set(FieldKey.password, "a"); v0.times = KDBX.Times(creationTime: t0, lastModificationTime: t0)
        var v1 = v0; v1.set(FieldKey.password, "b"); v1.times?.lastModificationTime = t1
        entry = v1; entry.set(FieldKey.notes, "nota"); entry.times?.lastModificationTime = t2
        entry.history = [v0, v1]
        #expect(entry.passwordChangedDate == t1)
        var fresh = v0; fresh.history = []
        #expect(fresh.passwordChangedDate == t0)
    }

    @Test func auditFindsSimilarShortCommonPwnedAndRespectsExclusion() {
        func entry(_ title: String, _ password: String, url: String = "") -> KDBX.Entry {
            var e = KDBX.Entry.make(title: title); e.set(FieldKey.password, password); e.set(FieldKey.url, url); return e
        }
        let a = entry("A", "Madrid2023!"), b = entry("B", "madrid2024")
        let c = entry("C", "abc"), d = entry("D", "password")
        var e = entry("E", "123"); e.qualityCheck = false
        let f = entry("F", "Zx9!kq#Lm2@vB7&wP4$t", url: "https://accounts.google.com/login")
        let audit = Audit(entries: [a, b, c, d, e, f],
                          pwnedCount: { $0 == "password" ? 9_000_000 : 0 },
                          twoFactorDomains: ["google.com"])
        #expect(audit.similar[a.uuid] == 1 && audit.similar[b.uuid] == 1)
        #expect(audit.short.contains(c.uuid))
        #expect(audit.common.contains(d.uuid))
        #expect(audit.pwned[d.uuid] == 9_000_000)
        #expect(!audit.all.contains(e.uuid))
        #expect(audit.missing2FA == [f.uuid])
        #expect(audit.issues(for: d.uuid).first?.hasPrefix("Ha aparecido en filtraciones") == true)
    }

    @Test func pwnedRangeParsing() {
        let hash = PwnedPasswords.sha1("password")
        #expect(hash == "5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8")
        let response = "0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n1E4C9B93F3F0682250B6CF8331B7EE68FD8:9545824\r\n"
        #expect(PwnedPasswords.count(in: response, suffix: String(hash.dropFirst(5))) == 9545824)
        #expect(PwnedPasswords.count(in: response, suffix: "FFFF") == 0)
    }

    @Test func twoFactorListParsing() {
        let json = #"[["Google",{"domain":"google.com","tfa":["sms","totp"],"additional-domains":["youtube.com"]}],["X",{"domain":"x.com","tfa":["sms"]}]]"#
        #expect(TwoFactorSites.parse(Data(json.utf8)) == ["google.com", "youtube.com"])
        #expect(TwoFactorSites.candidates(for: "https://www.login.bbva.es/x") == ["login.bbva.es", "bbva.es"])
    }

    @Test func csvAndPasteBetweenVaults() throws {
        let dir = try VaultTests.tempDir()
        var vault = try VaultTests.makeVault(in: dir)
        let id = try #require(vault.root.entries.first?.uuid)
        vault.updateEntry(id) { $0.set(FieldKey.notes, "con \"comillas\"") }
        let csv = vault.csv()
        #expect(csv.contains("\"GitHub\",\"david\",\"s3creta\""))
        #expect(csv.contains("\"con \"\"comillas\"\"\""))

        vault.addAttachment(named: "a.txt", data: Data("A".utf8), to: id)
        vault.setCustomIcon(Data([1, 2, 3]), for: id)
        let package = try #require(vault.package(id))

        let other = dir.appendingPathComponent("otra")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        var second = try VaultTests.makeVault(in: other)
        let pasted = second.paste(package, into: second.root.uuid)
        try second.save(backups: BackupStore(directory: dir.appendingPathComponent("copias")))
        let reopened = try Vault.open(url: second.url, unlock: UnlockData(masterPassword: "prueba"))
        let entry = try #require(reopened.locate(pasted)?.entry)
        #expect(pasted != id && entry.history.isEmpty)
        #expect(reopened.attachmentData(named: "a.txt", in: entry) == Data("A".utf8))
        #expect(reopened.customIconData(entry.customIconUUID) == Data([1, 2, 3]))

        vault.setCustomIcon(nil, for: id)
        #expect(vault.content.database.meta.customIcons.isEmpty)
    }

    @Test func cardKindIsStoredAndDetected() throws {
        var entry = KDBX.Entry.make(title: "Visa")
        entry.setKind(.card)
        #expect(entry.kind == .card)
        entry.setKind(.login)
        #expect(entry.customData.isEmpty && entry.kind == .login)
        entry.set(CardField.number, "4111111111111111", protected: true)
        #expect(entry.kind == .card)
    }
}
