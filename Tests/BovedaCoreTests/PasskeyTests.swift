import CryptoKit
import Foundation
import KDBXKit
import Testing
@testable import BovedaCore

@Suite struct PasskeyTests {
    @Test func rpIDMustBelongToTheOrigin() {
        #expect(WebAuthn.isAllowed(rpID: "github.com", origin: "https://github.com"))
        #expect(WebAuthn.isAllowed(rpID: "example.com", origin: "https://login.example.com"))
        #expect(WebAuthn.isAllowed(rpID: "localhost", origin: "http://localhost:8080"))
        #expect(!WebAuthn.isAllowed(rpID: "github.com", origin: "https://evil.com"))
        #expect(!WebAuthn.isAllowed(rpID: "hub.com", origin: "https://github.com"), "no basta con acabar igual")
        #expect(!WebAuthn.isAllowed(rpID: "github.io", origin: "https://david.github.io"), "github.io es un sufijo público")
        #expect(!WebAuthn.isAllowed(rpID: "com", origin: "https://github.com"))
        #expect(!WebAuthn.isAllowed(rpID: "github.com", origin: "http://github.com"), "solo https")
        #expect(!WebAuthn.isAllowed(rpID: "login.example.com", origin: "https://example.com"), "un hijo no vale")
    }

    @Test func clientDataHasStandardOrderAndEscaping() throws {
        let data = WebAuthn.clientData(.get, challenge: Data([1, 2, 255]), origin: "https://a.com")
        #expect(String(decoding: data, as: UTF8.self) == #"{"type":"webauthn.get","challenge":"AQL_","origin":"https://a.com","crossOrigin":false}"#)
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(parsed["origin"] as? String == "https://a.com")
    }

    @Test func registrationAndAssertionVerify() throws {
        let passkey = Passkey.make(relyingParty: "example.com", userName: "ana", userHandle: Data("u1".utf8))
        let created = passkey.registration(clientDataJSON: WebAuthn.clientData(.create, challenge: Data([9]), origin: "https://example.com"))
        // authenticatorData: hash del rpId, indicadores UP|UV|BE|BS|AT, contador y la clave COSE.
        #expect(created.authenticatorData.prefix(32) == Data(SHA256.hash(data: Data("example.com".utf8))))
        #expect(created.authenticatorData[32] == 0x5D)
        #expect(created.attestationObject.starts(with: [0xA3, 0x63] + Array("fmt".utf8)))
        #expect(try P256.Signing.PublicKey(derRepresentation: created.publicKey).rawRepresentation == passkey.privateKey.publicKey.rawRepresentation)

        let client = WebAuthn.clientData(.get, challenge: Data([7, 7]), origin: "https://example.com")
        let assertion = try passkey.assertion(clientDataJSON: client)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
        let signed = assertion.authenticatorData + Data(SHA256.hash(data: client))
        #expect(passkey.privateKey.publicKey.isValidSignature(signature, for: signed))
        #expect(assertion.authenticatorData.count == 37 && assertion.authenticatorData[32] == 0x1D)
    }

    @Test func storedInKeePassFieldsAndSurvivesSave() throws {
        let dir = try VaultTests.tempDir()
        var vault = try VaultTests.makeVault(in: dir)
        let passkey = Passkey.make(relyingParty: "example.com", userName: "ana", userHandle: Data([1, 2, 3]))
        var entry = KDBX.Entry.make(title: "example.com")
        passkey.write(into: &entry)
        #expect(entry.hasPasskey && entry.isProtected(Passkey.Key.privateKey))
        #expect(entry.string(Passkey.Key.privateKey).hasPrefix("-----BEGIN PRIVATE KEY-----"))
        vault.addEntry(entry, to: vault.root.uuid)
        try vault.save(backups: BackupStore(directory: dir.appendingPathComponent("copias")))
        let reopened = try Vault.open(url: vault.url, unlock: UnlockData(masterPassword: "prueba"))
        #expect(reopened.locate(entry.uuid)?.entry.passkey == passkey)
    }

    @Test func base64URLRoundTrip() {
        for length in 0..<40 {
            let data = Data((0..<length).map { UInt8(($0 * 37) & 0xff) })
            #expect(length == 0 || Base64URL.decode(Base64URL.encode(data)) == data)
        }
    }
}
