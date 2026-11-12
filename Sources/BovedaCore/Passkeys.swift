import CryptoKit
import Foundation
import KDBXKit

// MARK: - Claves de acceso (passkeys, WebAuthn)

/// Una clave de acceso guardada en una entrada, con los mismos campos que usan las apps KeePass
/// (`KPEX_PASSKEY_*`): así la misma passkey sirve en el Mac y en el móvil.
public struct Passkey: Equatable {
    public enum Key {
        public static let credentialID = "KPEX_PASSKEY_CREDENTIAL_ID"
        public static let privateKey = "KPEX_PASSKEY_PRIVATE_KEY_PEM"
        public static let relyingParty = "KPEX_PASSKEY_RELYING_PARTY"
        public static let userName = "KPEX_PASSKEY_USERNAME"
        public static let userHandle = "KPEX_PASSKEY_USER_HANDLE"
        public static let all = [credentialID, privateKey, relyingParty, userName, userHandle]
    }

    public var credentialID: Data
    public var privateKey: P256.Signing.PrivateKey
    public var relyingParty: String
    public var userName: String
    public var userHandle: Data

    public static func == (a: Passkey, b: Passkey) -> Bool {
        a.credentialID == b.credentialID && a.privateKey.rawRepresentation == b.privateKey.rawRepresentation
            && a.relyingParty == b.relyingParty && a.userName == b.userName && a.userHandle == b.userHandle
    }

    /// Clave nueva: identificador aleatorio de 32 bytes y clave P-256 (ES256, la que admiten todas las webs).
    public static func make(relyingParty: String, userName: String, userHandle: Data) -> Passkey {
        Passkey(credentialID: SecureRandom.bytes(32), privateKey: P256.Signing.PrivateKey(),
                relyingParty: relyingParty, userName: userName, userHandle: userHandle)
    }

    /// Lee la clave de una entrada (nil si no tiene o está incompleta).
    public init?(entry: KDBX.Entry) {
        guard let id = Base64URL.decode(entry.string(Key.credentialID)),
              let key = try? P256.Signing.PrivateKey(pemRepresentation: entry.string(Key.privateKey)),
              !entry.string(Key.relyingParty).isEmpty else { return nil }
        self.init(credentialID: id, privateKey: key, relyingParty: entry.string(Key.relyingParty),
                  userName: entry.string(Key.userName), userHandle: Base64URL.decode(entry.string(Key.userHandle)) ?? Data())
    }

    public init(credentialID: Data, privateKey: P256.Signing.PrivateKey, relyingParty: String, userName: String, userHandle: Data) {
        self.credentialID = credentialID
        self.privateKey = privateKey
        self.relyingParty = relyingParty
        self.userName = userName
        self.userHandle = userHandle
    }

    /// Guarda la clave en la entrada. La clave privada y el identificador de usuario van protegidos.
    public func write(into entry: inout KDBX.Entry) {
        entry.set(Key.credentialID, Base64URL.encode(credentialID), protected: false)
        entry.set(Key.privateKey, privateKey.pemRepresentation, protected: true)
        entry.set(Key.relyingParty, relyingParty, protected: false)
        entry.set(Key.userName, userName, protected: false)
        entry.set(Key.userHandle, Base64URL.encode(userHandle), protected: true)
    }

    public var credentialIDText: String { Base64URL.encode(credentialID) }

    // MARK: Respuestas WebAuthn

    /// Indicadores de authenticatorData: presencia (UP), verificación (UV), clave sincronizable (BE) y sincronizada (BS).
    private static let flags: UInt8 = 0x01 | 0x04 | 0x08 | 0x10

    private func authenticatorData(attested: Bool) -> Data {
        var data = Data(SHA256.hash(data: Data(relyingParty.utf8)))
        data.append(Self.flags | (attested ? 0x40 : 0))
        data.append(contentsOf: [0, 0, 0, 0]) // contador a 0: las claves sincronizadas no lo usan
        if attested {
            data.append(Data(count: 16)) // AAGUID vacío (atestación «none»)
            data.append(UInt8(credentialID.count >> 8))
            data.append(UInt8(credentialID.count & 0xff))
            data.append(credentialID)
            data.append(coseKey)
        }
        return data
    }

    /// Clave pública en formato COSE (EC2, P-256, ES256).
    private var coseKey: Data {
        let raw = privateKey.publicKey.rawRepresentation // x ‖ y
        return CBOR.map([
            (.int(1), .int(2)), (.int(3), .int(-7)), (.int(-1), .int(1)),
            (.int(-2), .bytes(raw.prefix(32))), (.int(-3), .bytes(raw.suffix(32))),
        ])
    }

    /// Respuesta a `navigator.credentials.create`.
    public func registration(clientDataJSON: Data) -> PasskeyRegistration {
        let authData = authenticatorData(attested: true)
        let attestation = CBOR.map([(.text("fmt"), .text("none")), (.text("attStmt"), .map([])), (.text("authData"), .bytes(authData))])
        return PasskeyRegistration(credentialID: credentialID, clientDataJSON: clientDataJSON, attestationObject: attestation,
                                   authenticatorData: authData, publicKey: privateKey.publicKey.derRepresentation)
    }

    /// Respuesta a `navigator.credentials.get`: firma de authenticatorData ‖ SHA-256(clientDataJSON).
    public func assertion(clientDataJSON: Data) throws -> PasskeyAssertion {
        let authData = authenticatorData(attested: false)
        let signature = try privateKey.signature(for: authData + Data(SHA256.hash(data: clientDataJSON)))
        return PasskeyAssertion(credentialID: credentialID, clientDataJSON: clientDataJSON, authenticatorData: authData,
                                signature: signature.derRepresentation, userHandle: userHandle)
    }
}

public struct PasskeyRegistration {
    public let credentialID: Data
    public let clientDataJSON: Data
    public let attestationObject: Data
    public let authenticatorData: Data
    /// SubjectPublicKeyInfo en DER (lo que devuelve `getPublicKey()`).
    public let publicKey: Data
}

public struct PasskeyAssertion {
    public let credentialID: Data
    public let clientDataJSON: Data
    public let authenticatorData: Data
    public let signature: Data
    public let userHandle: Data
}

// MARK: - Comprobaciones de origen

public enum WebAuthn {
    public enum Ceremony: String { case create = "webauthn.create", get = "webauthn.get" }

    /// La web solo puede usar claves de su propio dominio: el rpId tiene que ser el dominio de la página o uno
    /// de sus «padres», sin llegar a un sufijo público (una web de github.io no puede pedir claves de github.io).
    /// Solo https (o http://localhost para pruebas).
    public static func isAllowed(rpID: String, origin: String) -> Bool {
        guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(),
              !rpID.isEmpty else { return false }
        let rp = rpID.lowercased()
        let localhost = host == "localhost" || host.hasSuffix(".localhost")
        guard scheme == "https" || (scheme == "http" && localhost) else { return false }
        guard host == rp || host.hasSuffix("." + rp) else { return false }
        if localhost { return true }
        let site = BrowserMatch.site(of: host)
        return rp == site || rp.hasSuffix("." + site)
    }

    /// clientDataJSON con el orden de campos del estándar. El origen lo pone el navegador, nunca la página.
    public static func clientData(_ ceremony: Ceremony, challenge: Data, origin: String, crossOrigin: Bool = false) -> Data {
        func quoted(_ text: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
            return data.map { String(decoding: $0.dropFirst().dropLast(), as: UTF8.self) } ?? "\"\""
        }
        let json = "{\"type\":\(quoted(ceremony.rawValue)),\"challenge\":\(quoted(Base64URL.encode(challenge))),"
            + "\"origin\":\(quoted(origin)),\"crossOrigin\":\(crossOrigin)}"
        return Data(json.utf8)
    }
}

public extension KDBX.Entry {
    var passkey: Passkey? { Passkey(entry: self) }
}

// MARK: - Ayudas

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var base = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !base.isEmpty else { return nil }
        while base.count % 4 != 0 { base += "=" }
        return Data(base64Encoded: base)
    }
}

/// Lo justo de CBOR (RFC 8949) para la atestación y la clave COSE.
enum CBOR {
    indirect enum Value {
        case int(Int)
        case bytes(Data)
        case text(String)
        case map([(Value, Value)])
    }

    static func map(_ pairs: [(Value, Value)]) -> Data { encode(.map(pairs)) }

    static func encode(_ value: Value) -> Data {
        var out = Data()
        func head(_ major: UInt8, _ length: UInt64) {
            let type = major << 5
            switch length {
            case 0..<24: out.append(type | UInt8(length))
            case 24..<256: out.append(type | 24); out.append(UInt8(length))
            case 256..<65536: out.append(type | 25); out.append(contentsOf: [UInt8(length >> 8), UInt8(length & 0xff)])
            default: out.append(type | 26); out.append(contentsOf: (0..<4).reversed().map { UInt8((length >> ($0 * 8)) & 0xff) })
            }
        }
        func write(_ value: Value) {
            switch value {
            case let .int(n): n >= 0 ? head(0, UInt64(n)) : head(1, UInt64(-1 - n))
            case let .bytes(data): head(2, UInt64(data.count)); out.append(data)
            case let .text(text): let utf8 = Data(text.utf8); head(3, UInt64(utf8.count)); out.append(utf8)
            case let .map(pairs): head(5, UInt64(pairs.count)); for (k, v) in pairs { write(k); write(v) }
            }
        }
        write(value)
        return out
    }
}
