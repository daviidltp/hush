import Foundation
import KDBXKit

/// Qué entradas corresponden a la web abierta en el navegador.
/// Se compara el dominio registrable («accounts.google.com» y «mail.google.com» → «google.com») según la
/// Public Suffix List, como los navegadores: así «ana.github.io» y «pepe.github.io» son webs distintas.
/// Una contraseña guardada para https nunca se da a una página http.
public enum BrowserMatch {
    struct Address: Equatable {
        let scheme: String
        let host: String
    }

    /// Esquema y host (en minúsculas y punycode, sin puerto) de una dirección escrita a mano o completa.
    /// Sin esquema se supone https. El «www.» no se quita aquí: la Public Suffix List ya lo deja fuera del
    /// dominio registrable, salvo donde forma parte de él (www.ck).
    static func address(of text: String) -> Address? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("{REF:") else { return nil }
        let full = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
        else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard let ascii = Punycode.asciiHost(host) else { return nil }
        return Address(scheme: scheme, host: ascii)
    }

    /// Host de una dirección, sin «www.» ni puerto.
    public static func host(of text: String) -> String? {
        guard var host = address(of: text)?.host else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    // MARK: Public Suffix List

    private struct Rules {
        var normal: Set<String> = []
        var wildcard: Set<String> = []   // «*.ck» → «ck»
        var exception: Set<String> = []  // «!www.ck» → «www.ck»
    }

    private static let rules: Rules = {
        var rules = Rules()
        for line in PublicSuffixData.rules.split(separator: "\n") {
            if line.hasPrefix("!") { rules.exception.insert(String(line.dropFirst())) }
            else if line.hasPrefix("*.") { rules.wildcard.insert(String(line.dropFirst(2))) }
            else { rules.normal.insert(String(line)) }
        }
        return rules
    }()

    /// Número de etiquetas del sufijo público de un host (algoritmo de publicsuffix.org; sin regla, la última etiqueta).
    private static func suffixLength(_ labels: [Substring]) -> Int {
        var best = 1
        for start in 0..<labels.count {
            let candidate = labels[start...].joined(separator: ".")
            let count = labels.count - start
            if rules.exception.contains(candidate) { return count - 1 }
            if rules.normal.contains(candidate) { best = max(best, count) }
            if count < labels.count, rules.wildcard.contains(candidate) { best = max(best, count + 1) }
        }
        return best
    }

    /// Dominio registrable: «login.bbva.es» → «bbva.es», «shop.amazon.co.uk» → «amazon.co.uk»,
    /// «ana.github.io» → «ana.github.io». Las IP, los nombres sin punto (localhost) y los hosts que son
    /// un sufijo público se comparan enteros.
    public static func site(of host: String) -> String {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, !labels.contains(where: \.isEmpty), !labels.allSatisfy({ Int($0) != nil }),
              !host.contains(":") else { return host }
        let suffix = suffixLength(labels)
        guard suffix < labels.count else { return host }
        return labels.suffix(suffix + 1).joined(separator: ".")
    }

    /// Webs de una entrada: la principal y las adicionales (campos «KP2A_URL…», como en KeePassXC).
    public static func urls(of entry: KDBX.Entry) -> [String] {
        [entry.url] + entry.customFields.filter { $0.key.hasPrefix("KP2A_URL") }.map(\.value.revealedString)
    }

    public static func matches(page: String, entryURL: String) -> Bool {
        guard let page = address(of: page), let entry = address(of: entryURL) else { return false }
        // Lo guardado para https (o sin esquema) no se manda por una conexión sin cifrar.
        if page.scheme == "http" && entry.scheme == "https" { return false }
        return site(of: page.host) == site(of: entry.host)
    }

    public static func matches(page: String, entry: KDBX.Entry, resolve: (String) -> String = { $0 }) -> Bool {
        urls(of: entry).contains { matches(page: page, entryURL: resolve($0)) }
    }
}

/// Nombres de dominio con caracteres no ASCII → «xn--…» (RFC 3492), como los envía el navegador.
enum Punycode {
    static func asciiHost(_ host: String) -> String? {
        var labels: [String] = []
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            if label.unicodeScalars.allSatisfy(\.isASCII) { labels.append(String(label)); continue }
            guard let encoded = encode(String(label).precomposedStringWithCompatibilityMapping.lowercased()) else { return nil }
            labels.append("xn--" + encoded)
        }
        return labels.joined(separator: ".")
    }

    static func encode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        let scalars = input.unicodeScalars.map { Int($0.value) }
        func digit(_ d: Int) -> Character { Character(UnicodeScalar(UInt8(d < 26 ? d + 97 : d + 22))) }
        func adapt(_ delta: Int, _ points: Int, _ first: Bool) -> Int {
            var delta = first ? delta / damp : delta / 2
            delta += delta / points
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 { delta /= base - tMin; k += base }
            return k + (base - tMin + 1) * delta / (delta + skew)
        }
        var output = String(scalars.filter { $0 < 0x80 }.map { Character(UnicodeScalar(UInt8($0))) })
        let basic = output.count
        var handled = basic
        if basic > 0 { output.append("-") }
        var n = 0x80, delta = 0, bias = 72
        while handled < scalars.count {
            guard let m = scalars.filter({ $0 >= n }).min() else { return nil }
            delta += (m - n) * (handled + 1)
            n = m
            for c in scalars {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta, k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basic)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return output
    }
}
