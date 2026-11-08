import AppKit

// Ayudante mínimo que pone el icono de Hush en la barra de menús.
// En macOS 26, las apps con ciclo de vida de SwiftUI (como Hush) no consiguen mostrar iconos en la barra;
// una app de AppKit sí. Este proceso solo dibuja el icono y avisa a Hush cuando lo pulsas:
// el panel lo sigue abriendo Hush. Se cierra solo cuando Hush se cierra.
//
// Argumentos: --parent <pid de Hush> --id <identificador de Hush (com.david.boveda o .dev)>

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
let parent = argument("--parent").flatMap { pid_t($0) }
let identifier = argument("--id") ?? "com.david.boveda"

final class Helper: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let center = DistributedNotificationCenter.default()

    override init() {
        super.init()
        let image = Bundle.main.image(forResource: "menubar")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.setAccessibilityLabel("Hush")
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        center.addObserver(self, selector: #selector(state(_:)), name: .init(identifier + ".menubar.state"), object: nil)
        center.addObserver(self, selector: #selector(quit), name: .init(identifier + ".menubar.quit"), object: nil)
        // Si Hush se cierra (o se cae), el icono se va con ella.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            if let parent, kill(parent, 0) != 0 { NSApp.terminate(nil) }
        }
        // Pide a Hush el estado actual (bloqueada o no) para el nombre de VoiceOver.
        center.postNotificationName(.init(identifier + ".menubar.ready"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    @objc func clicked(_ sender: NSStatusBarButton) {
        guard let window = sender.window else { return }
        let frame = window.convertToScreen(sender.convert(sender.bounds, to: nil))
        center.postNotificationName(.init(identifier + ".menubar.clicked"), object: nil,
                                    userInfo: ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height],
                                    deliverImmediately: true)
    }

    @objc func state(_ note: Notification) {
        let locked = (note.userInfo?["locked"] as? Bool) ?? true
        item.button?.setAccessibilityLabel(locked ? "Hush, bloqueada" : "Hush, desbloqueada")
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let helper = Helper()
app.run()
