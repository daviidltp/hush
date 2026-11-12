import Foundation
import KDBXKit
import LocalAuthentication
import Security

/// Recuerda la clave de cada base en el llavero del iPhone, protegida con Face ID.
///
/// Se guarda la clave derivada de la base (no la contraseña maestra) con control de acceso
/// «biometría actual»: solo sale del llavero tras Face ID y deja de valer si cambian las caras
/// registradas. Nunca va a iCloud ni a copias de seguridad (`ThisDeviceOnly`). El llavero está
/// compartido con la extensión de autorrelleno.
enum BiometricKeychain {
    private static let service = "com.david.hush.unlock"

    enum Failure: LocalizedError {
        case cancelled
        /// Ha pulsado «Usar contraseña» en el aviso de Face ID.
        case wantsPassword
        case notFound
        case failed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .cancelled, .wantsPassword: return "Has cancelado Face ID."
            case .notFound: return "Face ID ya no vale para esta base. Escribe la contraseña maestra."
            case let .failed(status): return "No se ha podido usar Face ID (\(status))."
            }
        }
    }

    static var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// Hay clave guardada para esta base (no pide Face ID para saberlo).
    static func has(_ account: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func save(_ unlock: UnlockData, account: String) throws {
        forget(account)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error) else {
            throw Failure.failed(errSecParam)
        }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: unlock.keyDataBytes.toData(),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.failed(status) }
    }

    /// Pide Face ID y devuelve la clave de la base.
    static func load(_ account: String, reason: String) async throws -> UnlockData {
        let context = LAContext()
        context.localizedCancelTitle = "Usar contraseña"
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let error as LAError where [.userCancel, .userFallback].contains(error.code) {
            // Los dos botones del aviso dicen «Usar contraseña».
            throw Failure.wantsPassword
        } catch let error as LAError where [.appCancel, .systemCancel].contains(error.code) {
            throw Failure.cancelled
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else { throw Failure.notFound }
            return UnlockData(rawKeyData: data)
        case errSecItemNotFound, errSecAuthFailed:
            forget(account)
            throw Failure.notFound
        case errSecUserCanceled:
            throw Failure.cancelled
        default:
            throw Failure.failed(status)
        }
    }

    static func forget(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
