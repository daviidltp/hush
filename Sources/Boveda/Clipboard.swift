import AppKit
import BovedaCore
import KDBXKit

/// Copia al portapapeles marcando el contenido como secreto, y lo borra pasado un tiempo si nadie lo ha cambiado.
@MainActor
enum Clipboard {
    private static var ourChangeCount: Int?
    private static var clearTask: Task<Void, Never>?

    static func copy(_ value: String, clearAfter seconds: Int) {
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.string, .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType")], owner: nil)
        board.setString(value, forType: .string)
        // Estos marcadores piden a los gestores de portapapeles que no guarden el valor en su historial.
        board.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        board.setString("", forType: .init("org.nspasteboard.TransientType"))
        ourChangeCount = board.changeCount
        clearTask?.cancel()
        guard seconds > 0 else { return }
        clearTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            clearIfOurs()
        }
    }

    static func clearIfOurs() {
        let board = NSPasteboard.general
        guard let ours = ourChangeCount, board.changeCount == ours else { return }
        board.clearContents()
        ourChangeCount = nil
    }
}
