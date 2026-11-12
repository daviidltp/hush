import CryptoKit
import Foundation
import KDBXKit
import LocalAuthentication
import Security

/// Desbloqueo con Touch ID.
///
/// Guarda la clave derivada de la base de datos (no la contraseña) cifrada con una clave que vive dentro
/// del Secure Enclave del Mac. Esa clave solo se puede usar tras poner una huella registrada; si se
/// añaden o quitan huellas deja de valer y hay que volver a escribir la contraseña maestra.
public enum QuickUnlock {
    public enum Failure: LocalizedError {
        case unavailable(String)
        case cancelled
        case invalidated
        case corrupted

        public var errorDescription: String? {
            switch self {
            case let .unavailable(reason): return L("Touch ID no está disponible: \(reason)")
            case .cancelled: return L("Has cancelado Touch ID.")
            case .invalidated: return L("Han cambiado las huellas del Mac. Escribe la contraseña maestra para volver a activar Touch ID.")
            case .corrupted: return L("Los datos de Touch ID no son válidos. Escribe la contraseña maestra.")
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

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Boveda/TouchID", isDirectory: true)
    }

    static func recordURL(for database: URL) -> URL {
        let id = SHA256.hash(data: Data(database.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(id + ".json")
    }

    public static var isAvailable: Bool {
        var error: NSError?
        return SecureEnclave.isAvailable && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    public static func isEnrolled(_ database: URL) -> Bool {
        FileManager.default.fileExists(atPath: recordURL(for: database).path)
    }

    public static func enrolledDate(_ database: URL) -> Date? {
        guard let data = try? Data(contentsOf: recordURL(for: database)),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        return record.created
    }

    public static func forget(_ database: URL) {
        try? FileManager.default.removeItem(at: recordURL(for: database))
    }

    /// Activa Touch ID para esta base de datos. No pide la huella: cifra con la clave pública del enclave.
    public static func enroll(_ unlock: UnlockData, for database: URL) throws {
        guard SecureEnclave.isAvailable else { throw Failure.unavailable(L("este Mac no tiene Secure Enclave")) }
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &cfError
        ) else {
            throw Failure.unavailable(cfError?.takeRetainedValue().localizedDescription ?? L("sin control de acceso"))
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
        let key = symmetricKey(shared, salt: salt, database: database)
        let sealed = try AES.GCM.seal(unlock.keyDataBytes.toData(), using: key).combined!
        let record = Record(enclaveKey: enclaveKey.dataRepresentation, ephemeralPublicKey: ephemeral.publicKey.rawRepresentation, salt: salt, sealed: sealed, created: Date())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = recordURL(for: database)
        try JSONEncoder().encode(record).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Pide la huella y devuelve la clave para abrir la base de datos.
    public static func unlock(_ database: URL, reason: String) async throws -> UnlockData {
        guard let data = try? Data(contentsOf: recordURL(for: database)),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { throw Failure.corrupted }
        let context = LAContext()
        context.localizedCancelTitle = L("Usar contraseña")
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback: throw Failure.cancelled
            case .biometryLockout: throw Failure.unavailable(L("demasiados intentos fallidos. Escribe la contraseña."))
            case .biometryNotEnrolled, .biometryNotAvailable: throw Failure.unavailable(error.localizedDescription)
            default: throw Failure.unavailable(error.localizedDescription)
            }
        }
        let enclaveKey: SecureEnclave.P256.KeyAgreement.PrivateKey
        do {
            enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: record.enclaveKey, authenticationContext: context)
        } catch {
            // Si las huellas han cambiado, el enclave ya no reconoce la clave.
            forget(database)
            throw Failure.invalidated
        }
        do {
            let ephemeralPublic = try P256.KeyAgreement.PublicKey(rawRepresentation: record.ephemeralPublicKey)
            let shared = try enclaveKey.sharedSecretFromKeyAgreement(with: ephemeralPublic)
            let key = symmetricKey(shared, salt: record.salt, database: database)
            let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: record.sealed), using: key)
            guard plain.count == 32 else { throw Failure.corrupted }
            return UnlockData(rawKeyData: plain)
        } catch let failure as Failure {
            throw failure
        } catch {
            forget(database)
            throw Failure.invalidated
        }
    }

    static func symmetricKey(_ shared: SharedSecret, salt: Data, database: URL) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(("boveda-touchid-v1:" + database.standardizedFileURL.path).utf8), outputByteCount: 32)
    }
}
