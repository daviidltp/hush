import CryptoKit
import ImageIO
import Observation
import UIKit

/// Logos de las webs de cada entrada, como en el Mac.
/// Se descargan directamente de cada web (sin servicios de terceros que vean qué webs tienes) y se guardan
/// en la caché de la app con el nombre cifrado por hash y protección completa de archivos de iOS.
@MainActor
@Observable
final class FaviconStore {
    static let shared = FaviconStore()

    private(set) var images: [String: UIImage] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var running = 0

    private static let maxConcurrent = 4
    /// Si una web no tiene logo, no se vuelve a intentar hasta pasada una semana.
    nonisolated private static let retryAfter: TimeInterval = 7 * 24 * 3600

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Iconos", directoryHint: .isDirectory)
    }

    /// Dominio de una URL tal y como la escribe la gente ("google.com", "https://x.com/login"…).
    nonisolated static func host(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("{REF:") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var host = url.host()?.lowercased(), host.contains(".") else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    func image(for urlText: String) -> UIImage? {
        guard Preferences.showFavicons, let host = Self.host(of: urlText) else { return nil }
        if let image = images[host] { return image }
        load(host)
        return nil
    }

    /// Al bloquear: fuera de la memoria (en disco siguen cifrados por iOS mientras el iPhone está bloqueado).
    func forget() {
        images.removeAll()
    }

    func clearCache() {
        images.removeAll()
        try? FileManager.default.removeItem(at: Self.folder)
    }

    private func load(_ host: String) {
        guard !inFlight.contains(host) else { return }
        inFlight.insert(host)
        queue.append(host)
        // Fuera del dibujado de la vista: no se puede cambiar el estado mientras SwiftUI pinta.
        Task { self.pump() }
    }

    private func pump() {
        while running < Self.maxConcurrent, !queue.isEmpty {
            let host = queue.removeFirst()
            running += 1
            Task {
                let file = Self.file(for: host)
                let png = await Task.detached(priority: .utility) { () -> Data? in
                    if let cached = try? Data(contentsOf: file.appendingPathExtension("png")) { return cached }
                    let missPath = file.appendingPathExtension("none").path
                    if let date = (try? FileManager.default.attributesOfItem(atPath: missPath))?[.modificationDate] as? Date,
                       Date().timeIntervalSince(date) < Self.retryAfter { return nil }
                    let fetched = await Self.fetch(host)
                    try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                    if let fetched {
                        try? fetched.write(to: file.appendingPathExtension("png"), options: [.atomic, .completeFileProtection])
                    } else {
                        FileManager.default.createFile(atPath: missPath, contents: Data(), attributes: [.protectionKey: FileProtectionType.complete])
                    }
                    return fetched
                }.value
                running -= 1
                inFlight.remove(host)
                if let png, let image = UIImage(data: png) { images[host] = image }
                pump()
            }
        }
    }

    nonisolated private static func file(for host: String) -> URL {
        let digest = SHA256.hash(data: Data(host.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: digest)
    }

    // MARK: Descarga

    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"]
        return URLSession(configuration: config)
    }()

    /// Busca el mejor logo: los que declara la página, apple-touch-icon y favicon.ico; si no hay, prueba con el dominio principal.
    nonisolated static func fetch(_ host: String) async -> Data? {
        var hosts = [host]
        let parts = host.split(separator: ".")
        if parts.count > 2 { hosts.append(parts.suffix(2).joined(separator: ".")) }
        for candidateHost in hosts {
            guard let base = URL(string: "https://\(candidateHost)/") else { continue }
            var candidates: [URL] = []
            if let (data, response) = await limitedData(from: base, limit: 300_000, truncate: true),
               let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                candidates += iconLinks(in: html, base: response.url ?? base)
            }
            candidates += [URL(string: "https://\(candidateHost)/apple-touch-icon.png")!, URL(string: "https://\(candidateHost)/favicon.ico")!]
            var seen: Set<URL> = []
            for url in candidates where seen.insert(url).inserted {
                if let png = await download(url) { return png }
            }
        }
        return nil
    }

    nonisolated private static func download(_ url: URL) async -> Data? {
        guard let (data, response) = await limitedData(from: url, limit: 2_000_000, truncate: false),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return thumbnail(data, size: 96)
    }

    /// Descarga como mucho `limit` bytes: un servidor no puede llenar la memoria con una respuesta enorme.
    nonisolated private static func limitedData(from url: URL, limit: Int, truncate: Bool) async -> (Data, URLResponse)? {
        guard let (bytes, response) = try? await session.bytes(from: url) else { return nil }
        if response.expectedContentLength > Int64(limit), !truncate { bytes.task.cancel(); return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit {
                    bytes.task.cancel()
                    if truncate { break } else { return nil }
                }
            }
        } catch { return nil }
        return (data, response)
    }

    /// Miniatura PNG con ImageIO: no descodifica la imagen entera, así una dimensión gigante no llena la memoria.
    nonisolated static func thumbnail(_ data: Data, size: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        // Del .ico se queda con el dibujo más grande.
        var best = 0, bestSide = 0
        for index in 0..<CGImageSourceGetCount(source) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let side = max(props?[kCGImagePropertyPixelWidth] as? Int ?? 0, props?[kCGImagePropertyPixelHeight] as? Int ?? 0)
            if side > 8192 { return nil }
            if side > bestSide { best = index; bestSide = side }
        }
        guard bestSide >= 16 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, best, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).pngData()
    }

    /// Enlaces <link rel="icon"> de la página, del más grande al más pequeño (sin SVG).
    nonisolated static func iconLinks(in html: String, base: URL) -> [URL] {
        guard let tagRegex = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var found: [(url: URL, score: Int)] = []
        for match in tagRegex.matches(in: html, range: range) {
            guard let r = Range(match.range, in: html) else { continue }
            let tag = String(html[r])
            guard let rel = attribute("rel", in: tag)?.lowercased(), rel.contains("icon"), !rel.contains("mask"),
                  let href = attribute("href", in: tag), !href.lowercased().hasSuffix(".svg"), !href.hasPrefix("data:"),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL, url.scheme == "https" || url.scheme == "http" else { continue }
            let size = attribute("sizes", in: tag).flatMap { Int($0.lowercased().split(separator: "x").first ?? "") } ?? (rel.contains("apple") ? 180 : 32)
            found.append((url, size))
        }
        return found.sorted { $0.score > $1.score }.map(\.url)
    }

    nonisolated private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for index in 1...3 {
            if let r = Range(match.range(at: index), in: tag) { return String(tag[r]) }
        }
        return nil
    }
}
