import BovedaCore
import Sparkle
import SwiftUI

/// Actualizaciones automáticas con Sparkle. Cada versión va firmada con una clave EdDSA cuya parte pública está
/// en el Info.plist (`SUPublicEDKey`): una actualización que no venga firmada con ella no se instala.
/// Solo se activa en las versiones publicadas; las compilaciones locales no traen la clave ni la dirección.
@MainActor
final class Updates {
    static let shared = Updates()

    private let controller: SPUStandardUpdaterController?

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let enabled = info["SUPublicEDKey"] is String && info["SUFeedURL"] is String
        controller = enabled ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
    }

    var isAvailable: Bool { controller != nil }

    func check() { controller?.checkForUpdates(nil) }
}

/// «Buscar actualizaciones…» en el menú de la app.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if Updates.shared.isAvailable {
                Button(L("Buscar actualizaciones…")) { Updates.shared.check() }
            }
        }
    }
}
