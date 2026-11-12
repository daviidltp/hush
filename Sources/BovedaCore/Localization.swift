import Foundation

/// Texto de la interfaz traducido al idioma del sistema. El español es el idioma de origen: la clave es el texto
/// en español y las traducciones viven en `Resources/i18n` (ver `scripts/i18n.py`).
/// Las interpolaciones (`L("Copia guardada en \(nombre)")`) se traducen con su formato (`%@`, `%lld`).
@inline(__always)
public func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: .main)
}

/// Idioma en el que se muestra la app (el primero de los suyos que el usuario prefiere), con la región del sistema.
/// Sirve para fechas y números: así no salen meses en español con la interfaz en inglés.
public let appLocale: Locale = {
    let language = Bundle.main.preferredLocalizations.first ?? "es"
    let region = Locale.current.region?.identifier
    return Locale(identifier: region.map { "\(language)_\($0)" } ?? language)
}()
