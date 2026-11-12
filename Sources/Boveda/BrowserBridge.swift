import AppKit
import Security
import BovedaCore
import Darwin
import KDBXKit

/// Autorrelleno en el navegador, como Bitwarden: la extensión habla con `hush-bridge` (mensajería nativa)
/// y el puente reenvía cada mensaje a la app por un socket local.
///
/// Seguridad:
/// - El socket solo lo puede abrir tu usuario (permisos 0600) y la app solo acepta al puente que va dentro de Hush.
/// - Cada navegador se empareja una vez: Hush pregunta antes de darle nada.
/// - Las contraseñas solo se dan para la web en la que estás, salvo que elijas otra a mano en la extensión.
@MainActor
final class BrowserBridge {
    static let shared = BrowserBridge()

    static let hostName = Bundle.main.bundleIdentifier == "com.david.boveda.dev" ? "com.david.hush.dev" : "com.david.hush"
    static let chromiumExtensionID = "jkldoamenpoepbimegeedoneeojddkoi"
    static let firefoxExtensionID = "hush@davidlopez.app"

    static var supportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Hush", directoryHint: .isDirectory)
    }
    static var socketURL: URL { supportFolder.appending(path: "\(Bundle.main.bundleIdentifier ?? "hush").sock") }
    static var bridgeURL: URL { Bundle.main.bundleURL.appending(path: "Contents/MacOS/hush-bridge") }
    /// Carpeta fija con la extensión, para cargarla en el navegador.
    static var extensionFolder: URL { supportFolder.appending(path: "Extension", directoryHint: .isDirectory) }

    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var pairing: Set<String> = []

    // MARK: Arranque

    func start() {
        installExtensionFiles()
        installHostManifests()
        listen()
    }

    private func listen() {
        let path = Self.socketURL.path
        try? FileManager.default.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(Self.supportFolder.path, 0o700)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else { close(fd); return }
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            guard Self.peerIsOurBridge(client) else { close(client); return }
            BridgeConnection(fd: client).start()
        }
        source.resume()
        acceptSource = source
    }

    /// Solo se acepta al `hush-bridge` de esta misma app, ejecutado por tu usuario.
    nonisolated private static func peerIsOurBridge(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let peer = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
        let ours = Bundle.main.bundleURL.appending(path: "Contents/MacOS/hush-bridge").resolvingSymlinksInPath().path
        guard peer == ours else { return false }
        // Cualquier programa podría ejecutar hush-bridge y hablar por él: solo vale si lo ha abierto un navegador.
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        let parent = pid_t(info.pbi_ppid)
        // Tampoco basta con que el padre sea un navegador: con ciertas opciones de arranque un navegador auténtico
        // puede lanzar un programa intermedio que ejecute hush-bridge con otra entrada. Por eso, además, la entrada
        // y la salida del puente tienen que ser tuberías cuyo otro extremo esté en ese mismo navegador.
        return parentIsBrowser(parent) && stdioConnects(pid, to: parent)
    }

    /// Tuberías abiertas por un proceso: descriptor → (este extremo, el otro extremo).
    nonisolated private static func pipes(of pid: pid_t) -> [Int32: (handle: UInt64, peer: UInt64)] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [:] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 32)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [:] }
        var result: [Int32: (UInt64, UInt64)] = [:]
        let size = Int32(MemoryLayout<pipe_fdinfo>.size)
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_PIPE {
            var info = pipe_fdinfo()
            if proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDPIPEINFO, &info, size) == size {
                result[fd.proc_fd] = (info.pipeinfo.pipe_handle, info.pipeinfo.pipe_peerhandle)
            }
        }
        return result
    }

    nonisolated private static func stdioConnects(_ pid: pid_t, to parent: pid_t) -> Bool {
        let bridge = pipes(of: pid)
        guard let input = bridge[STDIN_FILENO], let output = bridge[STDOUT_FILENO] else { return false }
        let browserEnds = Set(pipes(of: parent).values.map(\.handle))
        return browserEnds.contains(input.peer) && browserEnds.contains(output.peer)
    }

    /// Equipos de desarrollador (Apple) de los navegadores admitidos. Se exige su firma, no solo el nombre:
    /// cualquiera puede llamar «Google Chrome» a un programa, pero no firmarlo con el equipo de Google.
    nonisolated private static let browserTeams = [
        "EQHXZ8M8AV", // Google (Chrome)
        "KL8N8XSYF4", // Brave
        "UBF8T346G9", // Microsoft (Edge)
        "43AQ936H96", // Mozilla (Firefox)
        "9V5K9TP787", // Zen
        "S6N382Y83G", // The Browser Company (Arc, Dia)
        "4XF3XNRN6Y", // Vivaldi
        "A2P9LX4JPN", // Opera
        "S4Q33XPHB4", // imput (Helium)
    ]

    nonisolated private static func parentIsBrowser(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        let teams = browserTeams.map { "certificate leaf[subject.OU] = \"\($0)\"" }.joined(separator: " or ")
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic and (\(teams))" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    // MARK: Instalación en los navegadores

    /// Navegadores basados en Chrome: carpeta de datos dentro de «Application Support».
    private static let chromiumFolders = [
        "Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary", "Chromium", "BraveSoftware/Brave-Browser",
        "Microsoft Edge", "Vivaldi", "Arc/User Data", "Dia/User Data", "Comet", "com.operasoftware.Opera",
        "net.imput.helium",
    ]
    /// Firefox y derivados (Zen, LibreWolf…) leen la carpeta de Mozilla.
    private static let firefoxFolders = ["Mozilla", "zen", "librewolf", "Waterfox"]

    private func installHostManifests() {
        let support = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        let bridge = Self.bridgeURL.path
        guard FileManager.default.isExecutableFile(atPath: bridge) else { return }
        let chromium: [String: Any] = [
            "name": Self.hostName, "description": "Hush", "path": bridge, "type": "stdio",
            "allowed_origins": ["chrome-extension://\(Self.chromiumExtensionID)/"],
        ]
        let firefox: [String: Any] = [
            "name": Self.hostName, "description": "Hush", "path": bridge, "type": "stdio",
            "allowed_extensions": [Self.firefoxExtensionID],
        ]
        func write(_ manifest: [String: Any], into folder: URL) {
            let dir = folder.appending(path: "NativeMessagingHosts", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes]) else { return }
            try? data.write(to: dir.appending(path: "\(Self.hostName).json"), options: .atomic)
        }
        for name in Self.chromiumFolders {
            let folder = support.appending(path: name, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: folder.path) { write(chromium, into: folder) }
        }
        let firefoxInstalled = Self.firefoxFolders.contains { FileManager.default.fileExists(atPath: support.appending(path: $0).path) }
        if firefoxInstalled {
            // Firefox (y Zen) buscan siempre en «Mozilla», aunque guarden sus perfiles en otra carpeta.
            write(firefox, into: support.appending(path: "Mozilla", directoryHint: .isDirectory))
        }
    }

    /// Copia la extensión que va dentro de la app a una carpeta fija (la que se carga en el navegador).
    private func installExtensionFiles() {
        guard let bundled = Bundle.main.resourceURL?.appending(path: "Extension", directoryHint: .isDirectory),
              FileManager.default.fileExists(atPath: bundled.path) else { return }
        let target = Self.extensionFolder
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: bundled, to: target)
    }

    // MARK: Navegadores emparejados

    private static let pairedKey = "browserClients"

    /// Navegadores aceptados: identificador de la extensión → nombre del navegador.
    static var paired: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: pairedKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: pairedKey) }
    }

    /// Código corto que la extensión enseña igual, para comprobar que es ella la que pide permiso.
    static func code(for client: String) -> String {
        let hex = client.uppercased().filter(\.isHexDigit)
        return hex.prefix(4) + "-" + hex.dropFirst(4).prefix(4)
    }

    // MARK: Peticiones

    func handle(_ message: [String: Any], browser: String) async -> [String: Any] {
        guard let type = message["type"] as? String, let client = message["client"] as? String, client.count >= 16 else {
            return ["error": "bad-request"]
        }
        if type == "pair" { return await pair(client, browser: browser) }
        guard Self.paired[client] != nil else { return ["error": "unpaired"] }
        guard let model = AppModel.shared else { return ["error": "offline"] }
        if type == "unlock" {
            model.showMainWindow()
            return ["ok": true]
        }
        if type == "status" { return ["locked": model.openVaults.isEmpty] }
        guard !model.openVaults.isEmpty else { return ["locked": true] }

        switch type {
        case "list":
            let page = message["url"] as? String ?? ""
            return ["entries": entries(in: model) { vault, entry in BrowserMatch.matches(page: page, entry: entry, resolve: { vault.resolve($0) }) }]
        case "search":
            let terms = (message["query"] as? String ?? "").lowercased().split(separator: " ").map(String.init)
            guard !terms.isEmpty else { return ["entries": []] }
            return ["entries": Array(entries(in: model) { _, entry in
                let text = [entry.title, entry.userName, entry.url].joined(separator: " ").lowercased()
                return terms.allSatisfy(text.contains)
            }.prefix(40))]
        case "fill", "copy":
            guard let found = locate(message, in: model) else { return ["error": "not-found"] }
            let (vault, entry) = found
            let page = message["url"] as? String ?? ""
            // Desde la página solo se rellena si la web coincide; desde la ventanita de la extensión, lo que elijas.
            let explicit = message["explicit"] as? Bool ?? false
            guard explicit || BrowserMatch.matches(page: page, entry: entry, resolve: { vault.resolve($0) }) else { return ["error": "wrong-site"] }
            // Ni eligiéndola a mano: una contraseña de https no se escribe en una página sin cifrar.
            if type == "fill", explicit, page.lowercased().hasPrefix("http:"),
               !BrowserMatch.urls(of: entry).contains(where: { vault.resolve($0).lowercased().hasPrefix("http:") }) {
                return ["error": "insecure-page"]
            }
            model.noteActivity()
            AppModel.markUsed(entry.uuid, in: vault.url)
            let user = vault.resolve(entry.userName), password = vault.resolve(entry.string(FieldKey.password))
            if type == "copy" {
                switch message["field"] as? String {
                case "user": Clipboard.copy(user, clearAfter: Preferences.clipboardSeconds)
                case "totp":
                    guard let totp = TOTP.from(entry) else { return ["error": "no-totp"] }
                    Clipboard.copy(totp.code(), clearAfter: Preferences.clipboardSeconds)
                default: Clipboard.copy(password, clearAfter: Preferences.clipboardSeconds)
                }
                return ["ok": true]
            }
            // Como Bitwarden: tras rellenar, el código 2FA queda copiado para pegarlo en el paso siguiente.
            var reply: [String: Any] = ["user": user, "password": password]
            if let totp = TOTP.from(entry) {
                Clipboard.copy(totp.code(), clearAfter: Preferences.clipboardSeconds)
                reply["totpCopied"] = true
            }
            return reply
        default:
            return ["error": "bad-request"]
        }
    }

    private func pair(_ client: String, browser: String) async -> [String: Any] {
        if Self.paired[client] != nil { return ["paired": true] }
        guard !pairing.contains(client) else { return ["error": "pending"] }
        pairing.insert(client)
        defer { pairing.remove(client) }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L("¿Conectar \(browser) con Hush?")
        alert.informativeText = L("Podrá rellenar tus contraseñas en las webs que visites. Comprueba que la extensión muestra el código \(Self.code(for: client)). Si no has pedido esto, pulsa «No conectar».")
        alert.addButton(withTitle: L("Conectar"))
        alert.addButton(withTitle: L("No conectar"))
        guard alert.runModal() == .alertFirstButtonReturn else { return ["error": "denied"] }
        Self.paired[client] = browser
        return ["paired": true]
    }

    private func entries(in model: AppModel, where include: (Vault, KDBX.Entry) -> Bool) -> [[String: Any]] {
        let recent = AppModel.recentEntryKeys
        var found: [(rank: Int, title: String, item: [String: Any])] = []
        for vault in model.openVaults {
            for entry in vault.root.allEntries(excluding: vault.excludedFromBrowsing) where entry.kind == .login && include(vault, entry) {
                let rank = recent.firstIndex(of: AppModel.recentKey(entry.uuid, in: vault.url)) ?? Int.max
                found.append((rank, entry.title, [
                    "uuid": entry.uuid.uuidString, "vault": vault.url.path, "vaultName": vault.name,
                    "title": entry.title.isEmpty ? L("Sin título") : entry.title, "user": vault.resolve(entry.userName),
                    "url": vault.resolve(entry.url), "totp": TOTP.from(entry) != nil,
                ]))
            }
        }
        // Primero las que has usado hace poco; luego por nombre.
        return found.sorted { a, b in
            a.rank != b.rank ? a.rank < b.rank : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }.map(\.item)
    }

    private func locate(_ message: [String: Any], in model: AppModel) -> (Vault, KDBX.Entry)? {
        guard let text = message["uuid"] as? String, let id = UUID(uuidString: text), let path = message["vault"] as? String,
              let vault = model.openVaults.first(where: { $0.url.path == path }),
              let entry = vault.locate(id)?.entry, entry.kind == .login, !vault.isInRecycleBin(id) else { return nil }
        return (vault, entry)
    }
}

/// Una conexión del puente: mensajes con 4 bytes de longitud delante, igual que la mensajería nativa.
private final class BridgeConnection: @unchecked Sendable {
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "hush.bridge.write")
    private var browser = L("El navegador")
    /// Se marca (en la cola de escritura) al cerrar, para no escribir en un descriptor ya cerrado.
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        // Si el puente se va mientras respondemos, que falle la escritura en vez de cerrar la app (SIGPIPE).
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        Thread.detachNewThread { [self] in
            while let message = readMessage() {
                if message["type"] as? String == "_bridge" {
                    if let name = message["browser"] as? String, !name.isEmpty { browser = name }
                    continue
                }
                let id = message["id"]
                let browser = browser
                Task { @MainActor in
                    var reply = await BrowserBridge.shared.handle(message, browser: browser)
                    reply["id"] = id
                    self.send(reply)
                }
            }
            writeQueue.sync { closed = true; close(fd) }
        }
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
            if n <= 0 { return nil }
            offset += n
        }
        return data
    }

    private func readMessage() -> [String: Any]? {
        guard let header = readExactly(4) else { return nil }
        let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        guard length > 0, length < 1_048_576, let body = readExactly(length) else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    private func send(_ reply: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: reply) else { return }
        var length = UInt32(body.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        writeQueue.async { [self] in
            guard !closed else { return }
            frame.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n <= 0 { return }
                    offset += n
                }
            }
        }
    }
}
