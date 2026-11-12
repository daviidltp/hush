import CryptoKit
import Foundation
import KDBXKit
import LocalAuthentication
import Security

/// Desbloqueo con Touch ID (Mac) o Face ID (iPhone).
///
/// Guarda la clave derivada de la base de datos (no la contraseña) cifrada con una clave que vive dentro
/// del Secure Enclave. Esa clave solo se puede usar tras poner una huella o cara registrada; si se
/// añaden o quitan deja de valer y hay que volver a escribir la contraseña maestra.
///
/// Cada base se identifica por una clave de texto: en el Mac, la ruta del archivo; en el iPhone, un
/// identificador propio, porque la ruta de un archivo de iCloud o Dropbox puede cambiar.
public enum QuickUnlock {
    #if os(iOS)
    static let biometry = "Face ID"
    static let device = "este iPhone"
    #else
    static let biometry = "Touch ID"
    static let device = "este Mac"
    #endif

    public enum Failure: LocalizedError {
        case unavailable(String)
        case cancelled
        case invalidated
        case corrupted

        public var errorDescription: String? {
            switch self {
            case let .unavailable(reason): return "\(QuickUnlock.biometry) no está disponible: \(reason)"
            case .cancelled: return "Has cancelado \(QuickUnlock.biometry)."
            case .invalidated: return "Han cambiado las huellas o caras de \(QuickUnlock.device). Escribe la contraseña maestra para volver a activar \(QuickUnlock.biometry)."
            case .corrupted: return "Los datos de \(QuickUnlock.biometry) no son válidos. Escribe la contraseña maestra."
            }
        }
    }

    struct Record: Codable {
        var version = 1
        var enclaveKey: Data
        var ephemeralPublicKey: Data
        var salt: Data
        var sealed: Data
        var created: Date
    }

    /// Carpeta de los registros. En el iPhone se cambia por la del grupo de apps, para que la extensión
    /// de autorrelleno pueda usar Face ID con las mismas bases.
    nonisolated(unsafe) public static var directoryOverride: URL?

    static var directory: URL {
        directoryOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Boveda/TouchID", isDirectory: true)
    }

    static func key(_ database: URL) -> String { database.standardizedFileURL.path }

    static func recordURL(forKey key: String) -> URL {
        let id = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(id + ".json")
    }

    public static var isAvailable: Bool {
        var error: NSError?
        return SecureEnclave.isAvailable && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    public static func isEnrolled(_ database: URL) -> Bool { isEnrolled(key: key(database)) }
    public static func enrolledDate(_ database: URL) -> Date? { enrolledDate(key: key(database)) }
    public static func forget(_ database: URL) { forget(key: key(database)) }
    public static func enroll(_ unlock: UnlockData, for database: URL) throws { try enroll(unlock, key: key(database)) }
    public static func unlock(_ database: URL, reason: String) async throws -> UnlockData {
        try await unlock(key: key(database), reason: reason)
    }

    public static func isEnrolled(key: String) -> Bool {
        FileManager.default.fileExists(atPath: recordURL(forKey: key).path)
    }

    public static func enrolledDate(key: String) -> Date? {
        guard let data = try? Data(contentsOf: recordURL(forKey: key)),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return record.created
    }

    public static func forget(key: String) {
        try? FileManager.default.removeItem(at: recordURL(forKey: key))
    }

    /// Activa el desbloqueo rápido para esta base de datos. No pide la huella: cifra con la clave pública del enclave.
    public static func enroll(_ unlock: UnlockData, key: String) throws {
        guard SecureEnclave.isAvailable else { throw Failure.unavailable("\(device) no tiene Secure Enclave") }
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &cfError
        ) else {
            throw Failure.unavailable(cfError?.takeRetainedValue().localizedDescription ?? "sin control de acceso")
        }
        let enclaveKey: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        } catch {
            throw Failure.unavailable(error.localizedDescription)
        }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: enclaveKey.publicKey)
        let symmetric = symmetricKey(shared, salt: salt, key: key)
        let sealed = try AES.GCM.seal(unlock.keyDataBytes.toData(), using: symmetric).combined!
        let record = Record(enclaveKey: enclaveKey.dataRepresentation, ephemeralPublicKey: ephemeral.publicKey.rawRepresentation, salt: salt, sealed: sealed, created: Date())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = recordURL(forKey: key)
        try JSONEncoder().encode(record).write(to: url, options: writeOptions)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    #if os(iOS)
    static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
    #else
    static let writeOptions: Data.WritingOptions = [.atomic]
    #endif

    /// Pide la huella o la cara y devuelve la clave para abrir la base de datos.
    public static func unlock(key: String, reason: String) async throws -> UnlockData {
        guard let data = try? Data(contentsOf: recordURL(forKey: key)),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { throw Failure.corrupted }
        let context = LAContext()
        context.localizedCancelTitle = "Usar contraseña"
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback: throw Failure.cancelled
            case .biometryLockout: throw Failure.unavailable("demasiados intentos fallidos. Escribe la contraseña.")
            case .biometryNotEnrolled, .biometryNotAvailable: throw Failure.unavailable(error.localizedDescription)
            default: throw Failure.unavailable(error.localizedDescription)
            }
        }
        let enclaveKey: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: record.enclaveKey, authenticationContext: context)
        } catch {
            // Si las huellas han cambiado, el enclave ya no reconoce la clave.
            forget(key: key)
            throw Failure.invalidated
        }
        do {
            let ephemeralPublic = try P256.KeyAgreement.PublicKey(rawRepresentation: record.ephemeralPublicKey)
            let shared = try enclaveKey.sharedSecretFromKeyAgreement(with: ephemeralPublic)
            let symmetric = symmetricKey(shared, salt: record.salt, key: key)
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: record.sealed), using: symmetric)
            guard plain.count == 32 else { throw Failure.corrupted }
            return UnlockData(rawKeyData: plain)
        } catch let failure as Failure {
            throw failure
        } catch {
            forget(key: key)
            throw Failure.invalidated
        }
    }

    static func symmetricKey(_ shared: SharedSecret, salt: Data, key: String) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(("boveda-touchid-v1:" + key).utf8), outputByteCount: 32)
    }
}
