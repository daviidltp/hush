import BovedaCore
import KDBXKit
import XCTest

/// La lógica compartida corriendo en iOS: crear, guardar con copia previa, reabrir y no pisar cambios ajenos.
final class VaultIOSTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testCreateSaveAndReopen() throws {
        let url = folder.appendingPathComponent("Prueba.kdbx")
        let unlock = UnlockData(masterPassword: "prueba-ios")
        var vault = try Vault.create(at: url, name: "Prueba", unlock: unlock)
        var entry = KDBX.Entry.make(title: "Correo")
        entry.set(FieldKey.password, "secreto", protected: true)
        vault.addEntry(entry, to: vault.root.uuid)
        let backups = BackupStore(directory: folder.appendingPathComponent("Copias"))
        try vault.save(backups: backups)

        let reopened = try Vault.open(url: url, unlock: unlock)
        XCTAssertEqual(reopened.root.allEntries().first?.string(FieldKey.password), "secreto")
        XCTAssertEqual(backups.backups(for: url).count, 1)
        XCTAssertThrowsError(try Vault.open(url: url, unlock: UnlockData(masterPassword: "otra")))
    }

    func testDoesNotOverwriteExternalChanges() throws {
        let url = folder.appendingPathComponent("Prueba.kdbx")
        let unlock = UnlockData(masterPassword: "prueba-ios")
        var mine = try Vault.create(at: url, name: "Prueba", unlock: unlock)
        var other = try Vault.open(url: url, unlock: unlock)
        other.addEntry(.make(title: "Desde el Mac"), to: other.root.uuid)
        try other.save(backups: BackupStore(directory: folder.appendingPathComponent("Copias")))

        mine.addEntry(.make(title: "Desde el iPhone"), to: mine.root.uuid)
        XCTAssertThrowsError(try mine.save(backups: BackupStore(directory: folder.appendingPathComponent("Copias")))) { error in
            XCTAssertEqual(error as? VaultError, .changedOnDisk)
        }
        XCTAssertTrue(mine.changedOnDisk())
    }
}
