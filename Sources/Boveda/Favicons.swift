import AppKit
import ImageIO
import CryptoKit
import KDBXKit
import Observation
import SwiftUI

/// Logos de las webs de cada entrada.
/// Se descargan directamente de cada web (sin servicios de terceros que vean qué webs tienes)
/// y se guardan en la caché del Mac con el nombre cifrado por hash.
@MainActor
@Observable
final class FaviconStore {
    static let shared = FaviconStore()

    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var running = 0

    private static let maxConcurrent = 4
    /// Si una web no tiene logo, no se vuelve a intentar hasta pasada una semana.
    nonisolated private static let retryAfter: TimeInterval = 7 * 24 * 3600

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "com.david.boveda/Iconos", directoryHint: .isDirectory)
    }

    /// Dominio de una URL tal y como la escribe la gente ("google.com", "https://x.com/login"…).
    static func host(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var host = url.host()?.lowercased(), host.contains(".") else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    func image(for urlText: String) -> NSImage? {
        guard Preferences.showFavicons, let host = Self.host(of: urlText) else { return nil }
        if let image = images[host] { return image }
        load(host)
        return nil
    }

    /// Empieza a descargar los logos que falten. Devuelve cuántos.
    @discardableResult
    func prefetch(_ urls: [String]) -> Int {
        let hosts = Set(urls.compactMap(Self.host(of:))).filter { images[$0] == nil }
        for host in hosts { load(host) }
        return hosts.count
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
                    // Primero la caché del disco; si la web no tenía logo hace poco, no se insiste.
                    if let cached = try? Data(contentsOf: file.appendingPathExtension("png")) { return cached }
                    let missPath = file.appendingPathExtension("none").path
                    if let date = (try? FileManager.default.attributesOfItem(atPath: missPath))?[.modificationDate] as? Date,
                       Date().timeIntervalSince(date) < Self.retryAfter { return nil }
                    let fetched = await Self.fetch(host)
                    try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                    if let fetched { try? fetched.write(to: file.appendingPathExtension("png")) }
                    else { FileManager.default.createFile(atPath: missPath, contents: Data()) }
                    return fetched
                }.value
                running -= 1
                if let png, let image = NSImage(data: png) { images[host] = image }
                pump()
            }
        }
    }

    nonisolated private static func file(for host: String) -> URL {
        let digest = SHA256.hash(data: Data(host.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: digest)
    }

    // MARK: Descarga

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"]
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
            if let (data, response) = await limitedData(from: base, limit: 300_000, truncate: true), let html = String(data: data.prefix(300_000), encoding: .utf8) ?? String(data: data.prefix(300_000), encoding: .isoLatin1) {
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

    private nonisolated static func download(_ url: URL) async -> Data? {
        guard let (data, response) = await limitedData(from: url, limit: 2_000_000, truncate: false),
              (response as? HTTPURLResponse)?.statusCode == 200, reasonableDimensions(data),
              let image = NSImage(data: data), image.isValid else { return nil }
        // El tamaño real del mayor de los dibujos (un .ico trae varios).
        let pixels = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        guard pixels >= 16 || pixels == 0 else { return nil }
        return pngThumbnail(image, size: 64)
    }

    /// Descarga como mucho `limit` bytes: un servidor no puede llenar la memoria con una respuesta enorme.
    /// Con `truncate` se queda con el principio (HTML); sin él, si se pasa del límite no vale.
    private nonisolated static func limitedData(from url: URL, limit: Int, truncate: Bool) async -> (Data, URLResponse)? {
        guard let (bytes, response) = try? await session.bytes(from: url) else { return nil }
        if response.expectedContentLength > Int64(limit), !truncate { bytes.task.cancel(); return nil }
        var data = Data()
        data.reserveCapacity(min(Int(max(response.expectedContentLength, 0)), limit))
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

    /// Antes de descodificar: una imagen pequeña en bytes puede declarar dimensiones gigantes.
    private nonisolated static func reasonableDimensions(_ data: Data) -> Bool {
        // Lo que ImageIO no lee (un SVG) se dibuja vectorial a 64 px: no hay mapa de bits gigante que temer.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return true }
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { continue }
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            if width > 4096 || height > 4096 { return false }
        }
        return true
    }

    nonisolated static func pngThumbnail(_ image: NSImage, size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
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

    private nonisolated static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for index in 1...3 {
            if let r = Range(match.range(at: index), in: tag) { return String(tag[r]) }
        }
        return nil
    }
}

/// Icono de una entrada: el icono propio guardado en la base, el logo de su web o, si no hay, la inicial.
struct EntryIcon: View {
    @Environment(AppModel.self) private var model
    let entry: KDBX.Entry
    var size: CGFloat = 28
    var titleOverride: String?

    var body: some View {
        if let image = customIcon ?? FaviconStore.shared.image(for: entry.url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 0.64, height: size * 0.64)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(Theme.border))
        } else {
            EntryAvatar(title: titleOverride ?? entry.title, size: size)
        }
    }

    private var customIcon: NSImage? {
        guard let id = entry.customIconUUID,
              let icon = model.vault?.content.database.meta.customIcons.first(where: { $0.uuid == id }) else { return nil }
        return NSImage(data: icon.data)
    }
}
