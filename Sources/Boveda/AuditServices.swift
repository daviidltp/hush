import BovedaCore
import Foundation
import Observation

/// Comprobaciones de la auditoría que necesitan internet:
/// - Filtraciones (Have I Been Pwned): solo viajan 5 caracteres de la huella de cada contraseña.
/// - Webs que permiten 2FA: se descarga la lista pública de 2fa.directory; no se envía nada tuyo.
@MainActor
@Observable
final class AuditServices {
    static let shared = AuditServices()

    /// Sube cada vez que llegan resultados, para recalcular la auditoría.
    private(set) var version = 0
    private(set) var twoFactorDomains: Set<String> = []
    private(set) var checking = 0
    /// Contraseñas que no se han podido comprobar (sin conexión, error del servicio…).
    private(set) var failedChecks = 0
    /// Lista de webs con 2FA: hasta tenerla, «Sin 2FA» no puede decir que todo esté bien.
    enum ListState { case notLoaded, loading, ready, failed }
    private(set) var twoFactorList: ListState = .notLoaded

    /// Solo en memoria: guardar huellas de contraseñas en disco sería darle pistas a un atacante.
    @ObservationIgnored private var pwned: [String: Int] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var running = 0
    @ObservationIgnored private var loadingList = false
    @ObservationIgnored private var failed: Set<String> = []
    /// Sube al bloquear: las respuestas que lleguen de antes se ignoran.
    @ObservationIgnored private var generation = 0

    func touch() { version += 1 }

    /// Copia de los resultados para calcular la auditoría en segundo plano (huella → veces).
    func pwnedSnapshot() -> [String: Int] { pwned }

    /// Cuántas de estas contraseñas siguen pendientes o no se han podido comprobar (solo las de la base activa).
    func status(for passwords: [String]) -> (pending: Int, failed: Int) {
        _ = version; _ = checking; _ = failedChecks
        var pending = 0, failedCount = 0
        for password in Set(passwords) {
            let key = hash(password)
            if pwned[key] != nil { continue }
            if failed.contains(key), !inFlight.contains(key) { failedCount += 1 } else { pending += 1 }
        }
        return (pending, failedCount)
    }

    func pwnedCount(for password: String) -> Int? {
        _ = version  // Así las vistas que lo consultan se actualizan cuando llegan resultados.
        return pwned[hash(password)]
    }

    /// Sin caché: guardarla obligaría a tener las contraseñas en claro como claves, y el SHA-1 es instantáneo.
    private func hash(_ password: String) -> String { PwnedPasswords.sha1(password) }

    func checkBreaches(_ passwords: [String]) {
        let pending = Set(passwords.map(hash)).filter { pwned[$0] == nil && !inFlight.contains($0) }
        guard !pending.isEmpty else { return }
        failed.subtract(pending)
        failedChecks = failed.count
        inFlight.formUnion(pending)
        queue += pending
        checking += pending.count
        Task { self.pump() }
    }

    private func pump() {
        while running < 4, !queue.isEmpty {
            let hash = queue.removeFirst()
            running += 1
            let started = generation
            Task {
                let count = try? await PwnedPasswords.check(sha1: hash)
                guard started == generation else { return }
                running -= 1
                checking -= 1
                inFlight.remove(hash)
                if let count { pwned[hash] = count; failed.remove(hash) } else { failed.insert(hash) }
                if failedChecks != failed.count { failedChecks = failed.count }
                // Se agrupan los avisos para no recalcular la auditoría con cada respuesta.
                if count ?? 0 > 0 || queue.isEmpty { version += 1 }
                pump()
            }
        }
    }

    /// Olvida los resultados (al bloquear todo).
    func reset() {
        pwned.removeAll()
        queue.removeAll()
        inFlight.removeAll()
        failed.removeAll()
        failedChecks = 0
        checking = 0
        running = 0
        generation += 1
        version += 1
    }

    // MARK: Lista de webs con 2FA

    private static var listFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "com.david.boveda/2fa.json")
    }

    /// `fresh`: no usar la copia guardada (al reintentar tras un fallo).
    func loadTwoFactorList(fresh: Bool = false) {
        guard !loadingList else { return }
        loadingList = true
        if twoFactorList != .ready { twoFactorList = .loading }
        Task {
            let file = Self.listFile
            let (domains, download) = await Task.detached(priority: .utility) { () -> (Set<String>, Data?) in
                let age = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
                let cached = try? Data(contentsOf: file)
                if !fresh, let age, Date().timeIntervalSince(age) < 7 * 86400, let cached {
                    let domains = TwoFactorSites.parse(cached)
                    if !domains.isEmpty { return (domains, nil) }
                }
                if let url = URL(string: "https://api.2fa.directory/v3/totp.json"),
                   let (data, response) = try? await URLSession(configuration: .ephemeral).data(from: url),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    let domains = TwoFactorSites.parse(data)
                    if !domains.isEmpty { return (domains, data) }
                }
                // Sin red o con una respuesta que no se entiende: la copia antigua sirve si es válida.
                return (cached.map(TwoFactorSites.parse) ?? [], nil)
            }.value
            loadingList = false
            // Una respuesta que no se entiende no es «ninguna web tiene 2FA».
            guard !domains.isEmpty else { if twoFactorList != .ready { twoFactorList = .failed }; return }
            // Solo se guarda en caché una lista que se ha entendido.
            if let download {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? download.write(to: file, options: .atomic)
            }
            twoFactorList = .ready
            if domains != twoFactorDomains {
                twoFactorDomains = domains
                version += 1
            }
        }
    }
}
