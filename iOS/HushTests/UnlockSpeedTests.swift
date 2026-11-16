import BovedaCore
import KDBXKit
import XCTest

/// Que desbloquear no vuelva a tardar 10 s en el iPhone. Los límites son holgados (simulador en debug).
final class UnlockSpeedTests: XCTestCase {
    func testArgon2OpensQuickly() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Velocidad.kdbx")
        let unlock = UnlockData(masterPassword: "velocidad")
        _ = try Vault.create(at: url, name: "Velocidad", unlock: unlock)
        let start = Date()
        _ = try Vault.open(url: url, unlock: unlock)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// Base con AES-KDF de 1 millón de pasadas (como la demo). Antes: 5 s en el simulador.
    /// `TEST_RUNNER_HUSH_AES_DB=~/Desktop/demo-boveda/Demo.kdbx TEST_RUNNER_HUSH_AES_DB_PASSWORD=… xcodebuild test …`
    func testAESKDFOpensQuickly() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["HUSH_AES_DB"], let password = environment["HUSH_AES_DB_PASSWORD"] else {
            throw XCTSkip("Sin base AES-KDF")
        }
        let start = Date()
        _ = try Vault.open(url: URL(fileURLWithPath: path), unlock: UnlockData(masterPassword: password))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
    }
}
