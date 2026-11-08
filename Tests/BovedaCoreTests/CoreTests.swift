import Foundation
import KDBXKit
import Testing
@testable import BovedaCore

@Suite struct TOTPTests {
    @Test func rfc6238Vector() {
        // Vector oficial RFC 6238 (SHA1, 8 dígitos, t = 59 s).
        let totp = TOTP(secret: Data("12345678901234567890".utf8), digits: 8)
        #expect(totp.code(at: Date(timeIntervalSince1970: 59)) == "94287082")
        #expect(totp.code(at: Date(timeIntervalSince1970: 1111111109)) == "07081804")
    }

    @Test func parsesOtpauth() throws {
        let totp = try #require(TOTP.parse("otpauth://totp/Demo:david?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&period=30&digits=8&issuer=Demo"))
        #expect(totp.digits == 8)
        #expect(totp.code(at: Date(timeIntervalSince1970: 59)) == "94287082")
    }

    @Test func rejectsGarbage() {
        #expect(TOTP.parse("otpauth://hotp/x?secret=GEZDGNBV") == nil)
        #expect(TOTP.parse("no es base32!") == nil)
    }
}

@Suite struct GeneratorTests {
    @Test func respectsOptions() {
        var options = GeneratorOptions()
        options.length = 40
        options.symbols = false
        for _ in 0..<50 {
            let password = PasswordGenerator.generate(options)
            #expect(password.count == 40)
            #expect(password.allSatisfy { $0.isLetter || $0.isNumber })
            #expect(password.contains { $0.isNumber })
            #expect(password.contains { $0.isUppercase })
            #expect(!password.contains("l") && !password.contains("0"))
        }
    }
}

@Suite struct VaultTests {
    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boveda-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func makeVault(in dir: URL) throws -> Vault {
        let url = dir.appendingPathComponent("Prueba.kdbx")
        let unlock = UnlockData(masterPassword: "prueba")
        var content = KDBXContent.makeEmpty(databaseName: "Prueba", kdf: .argon2idDefault())
        var entry = KDBX.Entry.make(title: "GitHub")
        entry.set(FieldKey.userName, "david")
        entry.set(FieldKey.password, "s3creta")
        content.database.root.group.entries.append(entry)
        let vault = Vault(url: url, content: content, unlock: unlock, diskFingerprint: Data())
        try vault.serialized().write(to: url)
        return try Vault.open(url: url, unlock: unlock)
    }

    @Test func saveRoundTripKeepsHistoryAndBackups() throws {
        let dir = try Self.tempDir()
        var vault = try Self.makeVault(in: dir)
        let id = try #require(vault.root.entries.first?.uuid)
        vault.updateEntry(id) { $0.set(FieldKey.password, "nueva") }
        let backups = BackupStore(directory: dir.appendingPathComponent("copias"))
        try vault.save(backups: backups)

        let reopened = try Vault.open(url: vault.url, unlock: UnlockData(masterPassword: "prueba"))
        let entry = try #require(reopened.locate(id)?.entry)
        #expect(entry.string(FieldKey.password) == "nueva")
        #expect(entry.isProtected(FieldKey.password))
        #expect(entry.history.count == 1)
        #expect(entry.history.first?.string(FieldKey.password) == "s3creta")
        #expect(backups.backups(for: vault.url).count == 1)
    }

    @Test func wrongPasswordIsReported() throws {
        let dir = try Self.tempDir()
        let vault = try Self.makeVault(in: dir)
        #expect(throws: VaultError.wrongCredentials) {
            try Vault.open(url: vault.url, unlock: UnlockData(masterPassword: "mal"))
        }
    }

    @Test func refusesToOverwriteExternalChanges() throws {
        let dir = try Self.tempDir()
        var vault = try Self.makeVault(in: dir)
        // Otra app guarda el archivo mientras lo tenemos abierto.
        var other = try Vault.open(url: vault.url, unlock: UnlockData(masterPassword: "prueba"))
        other.addEntry(.make(title: "Desde el móvil"), to: other.root.uuid)
        try other.save(backups: BackupStore(directory: dir.appendingPathComponent("copias")))

        vault.addEntry(.make(title: "Desde el Mac"), to: vault.root.uuid)
        #expect(throws: VaultError.changedOnDisk) {
            try vault.save(backups: BackupStore(directory: dir.appendingPathComponent("copias")))
        }
    }

    @Test func deleteGoesToRecycleBinThenForever() throws {
        let dir = try Self.tempDir()
        var vault = try Self.makeVault(in: dir)
        let id = try #require(vault.root.entries.first?.uuid)
        vault.deleteEntry(id)
        #expect(vault.isInRecycleBin(id))
        #expect(vault.root.allEntries(excluding: vault.excludedFromBrowsing).isEmpty)
        vault.deleteEntry(id)
        #expect(vault.locate(id) == nil)
    }

    /// Comprueba que KeePassXC abre lo que guardamos (si está instalado).
    @Test func keepassxcCanReadOurFiles() throws {
        let cli = "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
        guard FileManager.default.isExecutableFile(atPath: cli) else { return }
        let dir = try Self.tempDir()
        var vault = try Self.makeVault(in: dir)
        let id = try #require(vault.root.entries.first?.uuid)
        vault.updateEntry(id) { $0.set(FieldKey.password, "comprobada") }
        try vault.save(backups: BackupStore(directory: dir.appendingPathComponent("copias")))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["show", "-s", "-a", "Password", vault.url.path, "GitHub"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data("prueba\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(text.contains("comprobada"))
    }

    /// Las fechas deben coincidir con las de KeePassXC (antes salían 2 días desplazadas).
    @Test func datesMatchKeePassXC() throws {
        let cli = "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
        guard FileManager.default.isExecutableFile(atPath: cli) else { return }
        let url = try Self.tempDir().appendingPathComponent("Fechas.kdbx")
        func run(_ args: [String], input: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = args
            let pipe = Pipe()
            process.standardInput = pipe
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            pipe.fileHandleForWriting.write(Data(input.utf8))
            try pipe.fileHandleForWriting.close()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try run(["db-create", "-p", url.path], input: "prueba\nprueba\n")
        try run(["add", url.path, "Hoy"], input: "prueba\n")
        let vault = try Vault.open(url: url, unlock: UnlockData(masterPassword: "prueba"))
        let created = try #require(vault.root.allEntries().first { $0.title == "Hoy" }?.times?.creationTime)
        #expect(abs(created.timeIntervalSinceNow) < 600)
    }

    /// Las contraseñas y campos ocultos deben guardarse cifrados (Protected="True") y seguir ocultos al reabrir.
    @Test func protectedFieldsStayProtected() throws {
        let dir = try Self.tempDir()
        var vault = try Self.makeVault(in: dir)
        let id = try #require(vault.root.entries.first?.uuid)
        vault.updateEntry(id) { $0.set("PIN", "1234", protected: true) }
        try vault.save(backups: BackupStore(directory: dir.appendingPathComponent("copias")))

        let reopened = try Vault.open(url: vault.url, unlock: UnlockData(masterPassword: "prueba"))
        let entry = try #require(reopened.locate(id)?.entry)
        #expect(entry.isProtected(FieldKey.password))
        #expect(entry.isProtected("PIN"))
        #expect(!entry.isProtected(FieldKey.userName))
        #expect(entry.string("PIN") == "1234")
        // Si se guardó con Protected="True", KDBXKit lo devuelve todavía cifrado (lazyInnerCipher).
        for key in [FieldKey.password, "PIN"] {
            let value = try #require(entry.strings.first { $0.key == key }?.value)
            guard case .lazyInnerCipher = value else {
                Issue.record("\(key) se guardó sin el cifrado interno")
                continue
            }
        }

        // Comprobación directa en el XML que exporta KeePassXC.
        let cli = "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
        guard FileManager.default.isExecutableFile(atPath: cli) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["show", vault.url.path, "GitHub"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data("prueba\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(text.contains("Password: PROTECTED"))
        #expect(!text.contains("s3creta"))
    }

    @Test func historyRespectsDatabaseLimit() throws {
        let dir = try Self.tempDir()
        var vault = try Self.makeVault(in: dir)
        let id = try #require(vault.root.entries.first?.uuid)
        vault.content.database.meta.historyMaxItems = .unlimited
        for i in 0..<15 { vault.updateEntry(id) { $0.set(FieldKey.notes, "v\(i)") } }
        #expect(vault.locate(id)?.entry.history.count == 15)
        vault.content.database.meta.historyMaxItems = .value(3)
        vault.updateEntry(id) { $0.set(FieldKey.notes, "final") }
        #expect(vault.locate(id)?.entry.history.count == 3)
    }

    @Test func changingMasterPasswordReencrypts() throws {
        let dir = try Self.tempDir()
        var vault = try Self.makeVault(in: dir)
        vault.changeCredentials(UnlockData(masterPassword: "nueva-clave"))
        try vault.save(backups: BackupStore(directory: dir.appendingPathComponent("copias")))
        #expect(throws: VaultError.wrongCredentials) {
            try Vault.open(url: vault.url, unlock: UnlockData(masterPassword: "prueba"))
        }
        let reopened = try Vault.open(url: vault.url, unlock: UnlockData(masterPassword: "nueva-clave"))
        #expect(reopened.root.entries.first?.title == "GitHub")
    }

    @Test func reportFindsReusedAndWeak() throws {
        var a = KDBX.Entry.make(title: "A"); a.set(FieldKey.password, "123456")
        var b = KDBX.Entry.make(title: "B"); b.set(FieldKey.password, "123456")
        var c = KDBX.Entry.make(title: "C"); c.set(FieldKey.password, "Zx9!kq#Lm2@vB7&wP4$t")
        let report = PasswordReport(entries: [a, b, c, .make(title: "D")])
        #expect(report.reused.count == 2)
        #expect(report.weak.count == 2)
        #expect(report.empty.count == 1)
    }

    @Test func disabledRecycleBinDeletesForever() throws {
        let dir = try Self.tempDir()
        var vault = try Self.makeVault(in: dir)
        vault.content.database.meta.recycleBinEnabled = false
        let id = try #require(vault.root.entries.first?.uuid)
        let groupID = vault.addGroup(named: "Temporal", to: vault.root.uuid)
        vault.deleteEntry(id)
        vault.deleteGroup(groupID)
        #expect(vault.locate(id) == nil)
        #expect(vault.root.group(groupID) == nil)
        #expect(vault.content.database.root.deletedObjects.contains { $0.uuid == id })
        #expect(vault.content.database.root.deletedObjects.contains { $0.uuid == groupID })
    }

    @Test func attachmentsRoundTripAndKeePassXCReadsThem() throws {
        let dir = try Self.tempDir()
        var vault = try Self.makeVault(in: dir)
        let id = try #require(vault.root.entries.first?.uuid)
        let pdf = Data((0..<5000).map { UInt8($0 % 251) })
        vault.addAttachment(named: "contrato.pdf", data: pdf, to: id)
        let second = vault.addAttachment(named: "contrato.pdf", data: Data("hola".utf8), to: id)
        #expect(second == "contrato (2).pdf")
        try vault.save(backups: BackupStore(directory: dir.appendingPathComponent("copias")))

        let reopened = try Vault.open(url: vault.url, unlock: UnlockData(masterPassword: "prueba"))
        let entry = try #require(reopened.locate(id)?.entry)
        #expect(reopened.attachments(of: entry).map(\.name) == ["contrato.pdf", "contrato (2).pdf"])
        #expect(reopened.attachmentData(named: "contrato.pdf", in: entry) == pdf)

        let cli = "/Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli"
        guard FileManager.default.isExecutableFile(atPath: cli) else { return }
        let out = dir.appendingPathComponent("exportado.pdf")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["attachment-export", vault.url.path, "GitHub", "contrato.pdf", out.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data("prueba\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try Data(contentsOf: out) == pdf)
    }

    @Test func removingAttachmentKeepsHistoryReadable() throws {
        let dir = try Self.tempDir()
        var vault = try Self.makeVault(in: dir)
        let id = try #require(vault.root.entries.first?.uuid)
        vault.addAttachment(named: "a.txt", data: Data("A".utf8), to: id)
        vault.addAttachment(named: "b.txt", data: Data("B".utf8), to: id)
        vault.removeAttachment(named: "a.txt", from: id)
        // El historial sigue usando "a.txt", así que no se puede borrar del archivo.
        #expect(vault.content.innerHeader.binaryContent.count == 2)
        // Sin historial, se compacta y la referencia de "b.txt" sigue apuntando bien.
        vault.root.mutateEntry(id) { $0.history = [] }
        vault.compactAttachments()
        #expect(vault.content.innerHeader.binaryContent.count == 1)
        try vault.save(backups: BackupStore(directory: dir.appendingPathComponent("copias")))
        let reopened = try Vault.open(url: vault.url, unlock: UnlockData(masterPassword: "prueba"))
        let entry = try #require(reopened.locate(id)?.entry)
        #expect(reopened.attachmentData(named: "b.txt", in: entry) == Data("B".utf8))
    }

    @Test func auditFlagsDuplicatesWeakAndExpired() {
        var a = KDBX.Entry.make(title: "A"); a.set(FieldKey.password, "123456")
        var b = KDBX.Entry.make(title: "B"); b.set(FieldKey.password, "123456")
        var c = KDBX.Entry.make(title: "C"); c.set(FieldKey.password, "Zx9!kq#Lm2@vB7&wP4$t")
        c.times?.expires = true
        c.times?.expiryTime = Date(timeIntervalSinceNow: -60)
        let audit = Audit(entries: [a, b, c, .make(title: "D")])
        #expect(audit.duplicates[a.uuid] == 2 && audit.duplicates[b.uuid] == 2)
        #expect(audit.weak.count == 2)
        #expect(audit.expired == [c.uuid])
        #expect(audit.all == [a.uuid, b.uuid, c.uuid])
        #expect(audit.issues(for: a.uuid).first == "Contraseña repetida en 2 entradas")
    }
}
