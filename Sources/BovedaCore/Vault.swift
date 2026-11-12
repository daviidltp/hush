import CryptoKit
import Foundation
import KDBXKit

/// Claves estándar de KeePass para los campos de una entrada.
public enum FieldKey {
    public static let title = "Title"
    public static let userName = "UserName"
    public static let password = "Password"
    public static let url = "URL"
    public static let notes = "Notes"
    public static let otp = "otp"
    public static let standard: Set<String> = [title, userName, password, url, notes]
}

/// Etiqueta que usamos para marcar favoritos (la misma que KeePassXC y Strongbox muestran como etiqueta).
public let favoriteTag = "Favorite"

public enum VaultError: LocalizedError, Equatable {
    case wrongCredentials
    case unreadable(String)
    case changedOnDisk
    case verificationFailed
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .wrongCredentials: return L("Contraseña o archivo de clave incorrectos.")
        case let .unreadable(reason): return L("No se ha podido abrir la base de datos: \(reason)")
        case .changedOnDisk: return L("El archivo ha cambiado fuera de la app (por ejemplo, desde el móvil). Recarga antes de guardar para no perder esos cambios.")
        case .verificationFailed: return L("La copia nueva no se ha podido verificar. No se ha guardado nada.")
        case let .writeFailed(reason): return L("No se ha podido guardar: \(reason)")
        }
    }
}

/// Una base de datos abierta. Guarda la clave en memoria protegida mientras está desbloqueada.
public struct Vault {
    public let url: URL
    public var content: KDBXContent
    public private(set) var unlock: UnlockData
    /// Huella del archivo tal y como estaba en disco al abrirlo o guardarlo; sirve para detectar cambios externos.
    public private(set) var diskFingerprint: Data

    public init(url: URL, content: KDBXContent, unlock: UnlockData, diskFingerprint: Data) {
        self.url = url
        self.content = content
        self.unlock = unlock
        self.diskFingerprint = diskFingerprint
    }

    /// Crea un archivo nuevo vacío y lo deja abierto.
    public static func create(at url: URL, name: String, unlock: UnlockData) throws -> Vault {
        var content = KDBXContent.makeEmpty(databaseName: name, kdf: .argon2idDefault())
        content.database.root.group.name = name
        let draft = Vault(url: url, content: content, unlock: unlock, diskFingerprint: Data())
        let bytes = try draft.serialized()
        do { try AtomicFileWriter.write(bytes, to: url) } catch { throw VaultError.writeFailed(String(describing: error)) }
        return try open(url: url, unlock: unlock)
    }

    public var root: KDBX.Group {
        get { content.database.root.group }
        set { content.database.root.group = newValue }
    }

    public var name: String {
        if let n = content.database.meta.databaseName, !n.isEmpty { return n }
        return url.deletingPathExtension().lastPathComponent
    }

    public var recycleBinUUID: UUID? { content.database.meta.recycleBinUUID }

    // MARK: Abrir y guardar

    public static func open(url: URL, unlock: UnlockData) throws -> Vault {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw VaultError.unreadable(error.localizedDescription) }
        do {
            let content = try KDBXReader.parse(data, unlockData: unlock)
            return Vault(url: url, content: content, unlock: unlock, diskFingerprint: fingerprint(data))
        } catch KDBXReader.Error.wrongCredentials {
            throw VaultError.wrongCredentials
        } catch {
            throw VaultError.unreadable(String(describing: error))
        }
    }

    public static func fingerprint(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// Serializa la base de datos con la clave actual.
    public func serialized() throws -> Data {
        let stream = OutputStream(toMemory: ())
        stream.open()
        defer { stream.close() }
        do {
            try KDBXWriter(to: stream).write(content, unlockData: unlock)
        } catch {
            throw VaultError.writeFailed(String(describing: error))
        }
        guard let data = stream.property(forKey: .dataWrittenToMemoryStreamKey) as? Data else {
            throw VaultError.writeFailed(L("sin datos"))
        }
        return data
    }

    /// Guarda de forma segura: comprueba que nadie ha cambiado el archivo, verifica que la copia nueva se abre,
    /// hace copia de seguridad de la versión anterior y reemplaza el archivo de forma atómica.
    public mutating func save(backups: BackupStore = .default) throws {
        let bytes = try serialized()
        // Nunca escribimos algo que no sepamos volver a abrir.
        do {
            let reopened = try KDBXReader.parse(bytes, unlockData: unlock)
            guard reopened.database.root.group.uuid == content.database.root.group.uuid else {
                throw VaultError.verificationFailed
            }
        } catch {
            throw VaultError.verificationFailed
        }

        // La comprobación de cambios externos va justo antes de escribir, con el archivo coordinado,
        // para que una sincronización durante la verificación no se pise.
        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                let current: Data
                do { current = try Data(contentsOf: target) } catch { throw VaultError.writeFailed(error.localizedDescription) }
                guard Self.fingerprint(current) == diskFingerprint else { throw VaultError.changedOnDisk }
                try backups.store(current, for: url)
                do { try AtomicFileWriter.write(bytes, to: target) } catch { throw VaultError.writeFailed(String(describing: error)) }
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
        if let coordinationError { throw VaultError.writeFailed(coordinationError.localizedDescription) }
        diskFingerprint = Self.fingerprint(bytes)
    }

    /// Cambia la clave con la que se cifrará el próximo guardado (cambiar contraseña maestra).
    public mutating func changeCredentials(_ newUnlock: UnlockData) {
        unlock = newUnlock
        content.database.meta.masterKeyChanged = Date()
    }

    /// Anota la huella de lo que otra copia de esta base acaba de guardar en disco (guardado en segundo plano).
    public mutating func adoptSavedFingerprint(_ fingerprint: Data) {
        diskFingerprint = fingerprint
    }

    /// Indica si el archivo en disco ya no es el que abrimos.
    public func changedOnDisk() -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return Self.fingerprint(data) != diskFingerprint
    }
}
