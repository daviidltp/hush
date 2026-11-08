import AppKit
import SwiftUI

/// Icono de Hush en la barra de menús.
/// En macOS 26, una app con ciclo de vida de SwiftUI no consigue mostrar iconos en la barra (ni con
/// `MenuBarExtra` ni con `NSStatusItem`): macOS los deja fuera de la pantalla. Por eso el icono lo pone
/// un ayudante mínimo de AppKit que va dentro de la app (Contents/Helpers/HushMenu.app). Cuando lo pulsas,
/// avisa a Hush y Hush abre aquí el mismo panel de siempre (MenuBarContent) justo debajo del icono.
@MainActor
final class MenuBarItem: NSObject {
    static let shared = MenuBarItem()

    private var panel: MenuBarPanel?
    private weak var model: AppModel?
    private var helper: NSRunningApplication?
    private let center = DistributedNotificationCenter.default()
    private let prefix = Bundle.main.bundleIdentifier ?? "com.david.boveda"

    func install(model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        center.addObserver(self, selector: #selector(clicked(_:)), name: .init(prefix + ".menubar.clicked"), object: nil)
        center.addObserver(self, selector: #selector(helperReady), name: .init(prefix + ".menubar.ready"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(quitHelper), name: NSApplication.willTerminateNotification, object: nil)
        update()
    }

    /// Pone o quita el icono según el ajuste y le pasa si Hush está bloqueada (para VoiceOver).
    func update() {
        guard let model else { return }
        guard model.menuBarIcon else {
            panel?.close()
            quitHelper()
            return
        }
        if helper == nil || helper?.isTerminated == true { launchHelper() }
        center.postNotificationName(.init(prefix + ".menubar.state"), object: nil,
                                    userInfo: ["locked": model.openURLs.isEmpty], deliverImmediately: true)
    }

    private func launchHelper() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HushMenu.app")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = ["--parent", String(ProcessInfo.processInfo.processIdentifier), "--id", prefix]
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            Task { @MainActor in self.helper = app }
        }
    }

    @objc private func quitHelper() {
        center.postNotificationName(.init(prefix + ".menubar.quit"), object: nil, userInfo: nil, deliverImmediately: true)
        helper = nil
    }

    @objc private func helperReady() { update() }

    /// Momento en que se cerró el panel: un clic en el icono con el panel abierto lo cierra
    /// (al perder el foco) y no debe volver a abrirlo.
    private var closedAt = Date.distantPast

    @objc private func clicked(_ note: Notification) {
        guard let model, let info = note.userInfo,
              let x = info["x"] as? Double, let y = info["y"] as? Double,
              let w = info["w"] as? Double else { return }
        if let panel, panel.isVisible { panel.close(); return }
        guard Date().timeIntervalSince(closedAt) > 0.3 else { return }
        let panel = self.panel ?? MenuBarPanel(onClose: { [weak self] in self?.closedAt = Date() })
        self.panel = panel
        let content = MenuBarContent(dismiss: { [weak panel] in panel?.close() })
            .ignoresSafeArea()  // Sin el hueco de la barra de título invisible.
            .environment(model)
            .foregroundStyle(Theme.text)
            .tint(Theme.text)
        panel.contentView = NSHostingView(rootView: content)
        // Lo que mide MenuBarContent (60 + 400 + 58 + bordes). Con fullSizeContentView el contenido ocupa
        // toda la ventana, así que se fija el marco entero (setContentSize le sumaría la barra de título).
        let size = NSSize(width: 380, height: 520)
        // Debajo del icono, alineado a su borde derecho y sin salirse de la pantalla.
        let anchor = NSRect(x: x, y: y, width: w, height: 0)
        var origin = NSPoint(x: anchor.maxX - size.width, y: anchor.minY - size.height - 6)
        if let visible = (NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

/// Ventanita bajo el icono. No activa Hush (como la búsqueda rápida): al copiar puedes pegar
/// directamente en la app de antes. Se cierra al hacer clic fuera o con Esc.
private final class MenuBarPanel: NSPanel {
    private let onClose: () -> Void
    override var canBecomeKey: Bool { true }

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
    }

    /// Clic fuera del panel (en otra app o en el escritorio): se cierra, como los menús de la barra.
    private var outsideClicks: Any?

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        if outsideClicks == nil {
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.close()
            }
        }
    }

    override func close() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
        super.close()
        onClose()
    }

    override func cancelOperation(_ sender: Any?) { close() }
}
