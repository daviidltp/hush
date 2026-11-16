//
// Copyright (c) 2025, Denis Dzyubenko <denis@ddenis.info>
//
// SPDX-License-Identifier: BSD-2-Clause
//

import _CryptoExtras
import Crypto
import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

enum AESKDF {
    /// AES-KDF: iterate AES-256-ECB single-block encryption `rounds` times
    /// over each half of the 32-byte input, then SHA-256 the result.
    ///
    /// Returns `SecureBytes` so the derived key is held in zero-on-deinit
    /// storage from the moment it's produced.
    static func derive(salt: Data, rounds: UInt64, _ password: SecureBytes) -> SecureBytes {
        precondition(salt.count == 32, "AESKDF: Invalid salt size")
        precondition(password.count == 32, "AESKDF: Invalid key size \(password.count) != 32")

        // `buffer` is the running AES-encrypted state. It holds key material;
        // we use Data here for the in-loop arithmetic (slicing + concat) but
        // wrap the final result in SecureBytes. The transient Data is zeroed
        // before this function returns.
        var buffer = password.toData()
        defer {
            buffer.withUnsafeMutableBytes { ptr in
                _ = ptr.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }

        // KeePass AES-KDF: the 32-byte input is split into two 16-byte blocks
        // and each is independently encrypted with AES-256-ECB `rounds` times
        // using `salt` as the key. Final output is SHA-256 of the concatenated
        // ciphertexts.
        //
        // See: https://keepass.info/help/kb/kdbx_4.html and the
        // KeePassXC reference implementation (`Kdbx4Reader::transformKeyAes`).

        var left = Array(buffer.prefix(16))
        var right = Array(buffer.suffix(16))
        #if canImport(CommonCrypto)
        // Parche Hush: un solo cifrador AES-ECB de CommonCrypto (clave expandida una vez, AES por
        // hardware) que cifra los dos bloques a la vez en cada pasada. Con `AES.permute` cada pasada
        // volvía a preparar la clave: 1 millón de pasadas tardaban 5 s en el simulador y más de 10 en
        // el iPhone; así, unas décimas.
        if AESKDF.fastRounds(salt: salt, rounds: rounds, left: &left, right: &right) == false {
            AESKDF.slowRounds(salt: salt, rounds: rounds, left: &left, right: &right)
        }
        #else
        AESKDF.slowRounds(salt: salt, rounds: rounds, left: &left, right: &right)
        #endif

        var combined = Data(left)
        combined.append(contentsOf: right)
        defer {
            combined.withUnsafeMutableBytes { ptr in
                _ = ptr.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }

        return SecureBytes(combined.sha256())
    }

    private static func slowRounds(salt: Data, rounds: UInt64, left: inout [UInt8], right: inout [UInt8]) {
        let key = SymmetricKey(data: salt)
        for _ in 0..<rounds {
            // AES.permute is single-block ECB; invariants above guarantee
            // success — failure here would be a swift-crypto bug.
            try! AES.permute(&left, key: key)
            try! AES.permute(&right, key: key)
        }
    }

    #if canImport(CommonCrypto)
    /// Devuelve false si CommonCrypto falla (entonces se usa el camino lento, que da lo mismo).
    private static func fastRounds(salt: Data, rounds: UInt64, left: inout [UInt8], right: inout [UInt8]) -> Bool {
        var cryptor: CCCryptorRef?
        let created = salt.withUnsafeBytes { key in
            CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            key.baseAddress, key.count, nil, &cryptor)
        }
        guard created == kCCSuccess, let cryptor else { return false }
        defer { CCCryptorRelease(cryptor) }
        var state = left + right
        defer { state.withUnsafeMutableBytes { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var ok = true
        state.withUnsafeMutableBytes { raw in
            var moved = 0
            for _ in 0..<rounds where ok {
                // ECB cifra cada bloque de 16 bytes por separado: los dos bloques van juntos en una llamada.
                ok = CCCryptorUpdate(cryptor, raw.baseAddress, 32, raw.baseAddress, 32, &moved) == kCCSuccess && moved == 32
            }
        }
        guard ok else { return false }
        left = Array(state[0..<16])
        right = Array(state[16..<32])
        return true
    }
    #endif
}
