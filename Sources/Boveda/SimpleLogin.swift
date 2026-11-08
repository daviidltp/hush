import Foundation
import Security

/// Alias de email con SimpleLogin: una dirección distinta para cada web que reenvía a tu correo.
/// La clave de la API se guarda en el llavero del Mac, nunca en la base de datos.
enum SimpleLogin {
    private static let service = "com.david.boveda.simplelogin"

    static var isConfigured: Bool { apiKey != nil }

    static var apiKey: String? {
        get {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Crea un alias aleatorio. Solo se envía el dominio de la web y el título, como nota del alias.
    static func createAlias(for host: String?, note: String) async throws -> String {
        guard let key = apiKey else { throw Failure(errorDescription: "Añade tu clave de SimpleLogin en Ajustes.") }
        var components = URLComponents(string: "https://app.simplelogin.io/api/alias/random/new")!
        if let host { components.queryItems = [URLQueryItem(name: "hostname", value: host)] }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Authentication")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["note": note.isEmpty ? "Creado desde Hush" : note])
        request.timeoutInterval = 15
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status), let alias = json?["alias"] as? String else {
            let message = json?["error"] as? String ?? "SimpleLogin no ha respondido bien."
            throw Failure(errorDescription: message)
        }
        return alias
    }
}
