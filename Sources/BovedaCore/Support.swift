import CryptoKit
import Foundation
import KDBXKit
import Security

// MARK: - Copias de seguridad

/// Guarda la versión anterior del archivo antes de cada guardado, fuera de la carpeta sincronizada.
public struct BackupStore {
    public let directory: URL
    public let keep: Int

    public init(directory: URL, keep: Int = 30) {
        self.directory = directory
        self.keep = keep
    }

    public static var `default`: BackupStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return BackupStore(directory: base.appendingPathComponent("Boveda/Copias", isDirectory: true))
    }

    public func store(_ data: Data, for url: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let stamp = Self.stampFormatter.string(from: Date())
            let base = url.deletingPathExtension().lastPathComponent
            let target = directory.appendingPathComponent("\(base) \(stamp).kdbx")
            try data.write(to: target, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try prune(base: base)
        } catch {
            throw VaultError.writeFailed("no se pudo hacer la copia de seguridad (\(error.localizedDescription))")
        }
    }

    public func backups(for url: URL) -> [URL] {
        let base = url.deletingPathExtension().lastPathComponent
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix(base + " ") && $0.pathExtension == "kdbx" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func prune(base: String) throws {
        let all = backups(for: URL(fileURLWithPath: base + ".kdbx"))
        for old in all.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()
}

// MARK: - Aleatoriedad segura

enum SecureRandom {
    /// Número uniforme en 0..<upper sin sesgo (muestreo con rechazo).
    static func uniform(_ upper: Int) -> Int {
        precondition(upper > 0)
        let bound = UInt32(upper)
        let limit = UInt32.max - UInt32.max % bound
        while true {
            var value: UInt32 = 0
            let status = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
            precondition(status == errSecSuccess, "Sin generador aleatorio del sistema")
            if value < limit { return Int(value % bound) }
        }
    }
}

// MARK: - Generador de contraseñas

public struct GeneratorOptions: Codable, Equatable {
    public var length = 24
    public var uppercase = true
    public var lowercase = true
    public var digits = true
    public var symbols = true
    public var avoidAmbiguous = true
    public var requireEachGroup = true
    /// Frase de palabras ("Caballo-Grapa-Bateria-7") en vez de caracteres sueltos.
    public var usePassphrase = false
    public var wordCount = 5
    public var separator = "-"
    public var capitalize = true
    public var addNumber = true
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case length, uppercase, lowercase, digits, symbols, avoidAmbiguous, requireEachGroup
        case usePassphrase, wordCount, separator, capitalize, addNumber
    }

    /// Lee también los ajustes guardados por versiones anteriores (sin las opciones de frase).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GeneratorOptions()
        length = try c.decodeIfPresent(Int.self, forKey: .length) ?? d.length
        uppercase = try c.decodeIfPresent(Bool.self, forKey: .uppercase) ?? d.uppercase
        lowercase = try c.decodeIfPresent(Bool.self, forKey: .lowercase) ?? d.lowercase
        digits = try c.decodeIfPresent(Bool.self, forKey: .digits) ?? d.digits
        symbols = try c.decodeIfPresent(Bool.self, forKey: .symbols) ?? d.symbols
        avoidAmbiguous = try c.decodeIfPresent(Bool.self, forKey: .avoidAmbiguous) ?? d.avoidAmbiguous
        requireEachGroup = try c.decodeIfPresent(Bool.self, forKey: .requireEachGroup) ?? d.requireEachGroup
        usePassphrase = try c.decodeIfPresent(Bool.self, forKey: .usePassphrase) ?? d.usePassphrase
        wordCount = try c.decodeIfPresent(Int.self, forKey: .wordCount) ?? d.wordCount
        separator = try c.decodeIfPresent(String.self, forKey: .separator) ?? d.separator
        capitalize = try c.decodeIfPresent(Bool.self, forKey: .capitalize) ?? d.capitalize
        addNumber = try c.decodeIfPresent(Bool.self, forKey: .addNumber) ?? d.addNumber
    }
}

public enum PasswordGenerator {
    static let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let lower = Array("abcdefghijklmnopqrstuvwxyz")
    static let digitChars = Array("0123456789")
    static let symbolChars = Array("!@#$%^&*()-_=+[]{};:,.?/~")
    static let ambiguous = Set("Il1O0o|`'\"")

    static func groups(_ o: GeneratorOptions) -> [[Character]] {
        var result: [[Character]] = []
        if o.uppercase { result.append(upper) }
        if o.lowercase { result.append(lower) }
        if o.digits { result.append(digitChars) }
        if o.symbols { result.append(symbolChars) }
        if result.isEmpty { result.append(lower) }
        if o.avoidAmbiguous { result = result.map { $0.filter { !ambiguous.contains($0) } } }
        return result
    }

    public static func generate(_ options: GeneratorOptions) -> String {
        if options.usePassphrase { return passphrase(options) }
        let sets = groups(options)
        let pool = sets.flatMap { $0 }
        let length = max(options.length, options.requireEachGroup ? sets.count : 1)
        var chars: [Character] = []
        if options.requireEachGroup { chars = sets.map { $0[SecureRandom.uniform($0.count)] } }
        while chars.count < length { chars.append(pool[SecureRandom.uniform(pool.count)]) }
        // Mezcla Fisher-Yates para que los obligatorios no queden al principio.
        for i in stride(from: chars.count - 1, to: 0, by: -1) { chars.swapAt(i, SecureRandom.uniform(i + 1)) }
        return String(chars)
    }

    /// Frase de palabras en español elegidas al azar (13 bits por palabra).
    public static func passphrase(_ options: GeneratorOptions) -> String {
        let words = SpanishWords.list
        var parts = (0..<max(options.wordCount, 2)).map { _ in words[SecureRandom.uniform(words.count)] }
        if options.capitalize { parts = parts.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
        if options.addNumber { parts.append(String(SecureRandom.uniform(100))) }
        return parts.joined(separator: options.separator)
    }

    public static func entropy(_ options: GeneratorOptions) -> Double {
        if options.usePassphrase {
            return Double(max(options.wordCount, 2)) * log2(Double(SpanishWords.list.count)) + (options.addNumber ? log2(100) : 0)
        }
        let pool = groups(options).reduce(0) { $0 + $1.count }
        return Double(options.length) * log2(Double(max(pool, 2)))
    }
}

/// Estimación sencilla de fortaleza para contraseñas que no hemos generado nosotros.
public enum PasswordStrength: Int, Comparable {
    case veryWeak, weak, fair, strong, veryStrong

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public static func bits(_ password: String) -> Double {
        guard !password.isEmpty else { return 0 }
        var pool = 0
        if password.contains(where: \.isLowercase) { pool += 26 }
        if password.contains(where: \.isUppercase) { pool += 26 }
        if password.contains(where: \.isNumber) { pool += 10 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 33 }
        let unique = Set(password).count
        // Penaliza repeticiones: cuenta caracteres únicos más la mitad del resto.
        let effective = Double(unique) + Double(password.count - unique) * 0.5
        return effective * log2(Double(max(pool, 2)))
    }

    public static func of(_ password: String) -> PasswordStrength {
        switch bits(password) {
        case ..<28: return .veryWeak
        case ..<45: return .weak
        case ..<64: return .fair
        case ..<100: return .strong
        default: return .veryStrong
        }
    }

    public var label: String {
        switch self {
        case .veryWeak: return "Muy débil"
        case .weak: return "Débil"
        case .fair: return "Aceptable"
        case .strong: return "Fuerte"
        case .veryStrong: return "Muy fuerte"
        }
    }

    public var fraction: Double { Double(rawValue + 1) / 5 }
}

// MARK: - Códigos 2FA (TOTP)

public struct TOTP: Equatable {
    public enum Algorithm: String { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    public var secret: Data
    public var digits: Int
    public var period: Int
    public var algorithm: Algorithm

    public static let fieldKeys: Set<String> = ["otp", "TOTP Seed", "TOTP Settings", "TimeOtp-Secret-Base32", "TimeOtp-Length", "TimeOtp-Period", "TimeOtp-Algorithm"]

    public init(secret: Data, digits: Int = 6, period: Int = 30, algorithm: Algorithm = .sha1) {
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    /// Lee el 2FA de una entrada en los formatos de KeePassXC/KeePassium (`otp`), KeePass 2 (`TimeOtp-*`) y el antiguo (`TOTP Seed`).
    public static func from(_ entry: KDBX.Entry) -> TOTP? {
        let otp = entry.string("otp")
        if !otp.isEmpty { return parse(otp) }
        let kp2 = entry.string("TimeOtp-Secret-Base32")
        if !kp2.isEmpty, let secret = base32Decode(kp2) {
            return TOTP(secret: secret,
                        digits: Int(entry.string("TimeOtp-Length")) ?? 6,
                        period: Int(entry.string("TimeOtp-Period")) ?? 30,
                        algorithm: Algorithm(rawValue: entry.string("TimeOtp-Algorithm").replacingOccurrences(of: "HMAC-", with: "").uppercased()) ?? .sha1)
        }
        let seed = entry.string("TOTP Seed")
        if !seed.isEmpty, let secret = base32Decode(seed) {
            let settings = entry.string("TOTP Settings").split(separator: ";")
            let period = settings.first.flatMap { Int($0) } ?? 30
            let digits = settings.count > 1 ? Int(settings[1]) ?? 6 : 6
            return TOTP(secret: secret, digits: digits, period: period)
        }
        return nil
    }

    /// Acepta un enlace `otpauth://totp/...` o directamente la clave en base32.
    public static func parse(_ text: String) -> TOTP? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "otpauth" else {
            return base32Decode(trimmed).map { TOTP(secret: $0) }
        }
        guard components.host?.lowercased() == "totp" else { return nil }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let secretText = items["secret"], let secret = base32Decode(secretText) else { return nil }
        let digits = Int(items["digits"] ?? "") ?? 6
        let period = Int(items["period"] ?? "") ?? 30
        let algorithm = Algorithm(rawValue: (items["algorithm"] ?? "SHA1").uppercased()) ?? .sha1
        guard (6...10).contains(digits), period > 0 else { return nil }
        return TOTP(secret: secret, digits: digits, period: period, algorithm: algorithm)
    }

    public func code(at date: Date = Date()) -> String {
        var counter = UInt64(date.timeIntervalSince1970 / Double(period)).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let key = SymmetricKey(data: secret)
        let mac: Data
        switch algorithm {
        case .sha1: mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: mac = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: mac = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let value = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16) | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var modulus: UInt64 = 1
        for _ in 0..<digits { modulus *= 10 }
        let code = String(UInt64(value) % modulus)
        return String(repeating: "0", count: max(0, digits - code.count)) + code
    }

    public func secondsRemaining(at date: Date = Date()) -> Int {
        period - Int(date.timeIntervalSince1970) % period
    }

    public static func base32Decode(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let clean = text.uppercased().filter { $0 != "=" && $0 != " " && $0 != "-" }
        guard !clean.isEmpty else { return nil }
        var buffer: UInt64 = 0
        var bits = 0
        var output = Data()
        for char in clean {
            guard let index = alphabet.firstIndex(of: char) else { return nil }
            buffer = (buffer << 5) | UInt64(index)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> UInt64(bits)) & 0xff))
            }
        }
        return output.isEmpty ? nil : output
    }
}
