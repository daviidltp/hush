import Darwin
import Foundation

// Puente entre la extensión del navegador y Hush.
// El navegador lo arranca (mensajería nativa) y habla por la entrada y salida estándar;
// aquí solo se reenvían los bytes al socket de la app y de vuelta. No guarda ni lee contraseñas.

let bundleID = Bundle.main.bundleIdentifier ?? "com.david.boveda"
let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/Hush/\(bundleID).sock").path

/// Nombre del navegador que nos ha abierto (el proceso padre), para que Hush lo enseñe al emparejar.
func browserName() -> String {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(getppid(), &buffer, UInt32(buffer.count)) > 0 else { return "" }
    let path = String(cString: buffer)
    guard let app = path.components(separatedBy: "/").first(where: { $0.hasSuffix(".app") }) else { return "" }
    return String(app.dropLast(4))
}

func connectSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: bytes)
        buffer[bytes.count] = 0
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) } }
    if result == 0 { return fd }
    close(fd)
    return nil
}

/// Si Hush no está abierta, se abre en segundo plano y se espera un poco a que escuche.
func connectOrLaunch() -> Int32? {
    if let fd = connectSocket() { return fd }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-b", bundleID]
    try? open.run()
    open.waitUntilExit()
    for _ in 0..<100 {
        usleep(100_000)
        if let fd = connectSocket() { return fd }
    }
    return nil
}

func writeAll(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Bool {
    var offset = 0
    while offset < count {
        let n = write(fd, pointer + offset, count - offset)
        if n <= 0 { return false }
        offset += n
    }
    return true
}

func frame(_ object: [String: Any]) -> Data {
    let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    var length = UInt32(body.count).littleEndian
    var data = Data(bytes: &length, count: 4)
    data.append(body)
    return data
}

signal(SIGPIPE, SIG_IGN)

guard let sock = connectOrLaunch() else {
    // Sin Hush: se avisa a la extensión y se sale.
    let reply = frame(["error": "offline"])
    reply.withUnsafeBytes { _ = writeAll(STDOUT_FILENO, $0.baseAddress!, $0.count) }
    exit(1)
}

let hello = frame(["type": "_bridge", "browser": browserName(), "origin": CommandLine.arguments.dropFirst().first ?? ""])
hello.withUnsafeBytes { _ = writeAll(sock, $0.baseAddress!, $0.count) }

/// Copia bytes de un descriptor a otro hasta que uno se cierre; entonces termina el puente.
func pump(from source: Int32, to target: Int32) -> Never {
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        let n = read(source, &buffer, buffer.count)
        if n <= 0 { exit(0) }
        if !buffer.withUnsafeBytes({ writeAll(target, $0.baseAddress!, n) }) { exit(0) }
    }
}

Thread.detachNewThread { pump(from: sock, to: STDOUT_FILENO) }
pump(from: STDIN_FILENO, to: sock)
