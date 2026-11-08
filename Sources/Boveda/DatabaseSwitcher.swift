import AppKit
import SwiftUI

/// Selector de bases de datos arriba de la barra lateral, como el de espacios de trabajo de Slack o Linear.
/// Muestra la base actual; al pulsar, la lista de bases con su estado y las acciones de la base.
struct DatabaseSwitcher: View {
    @Environment(AppModel.self) private var model
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.vault?.name ?? "")
                        .font(.ui(13, .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.ui(11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering || open ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Cambiar de base de datos")
        .accessibilityLabel("Base de datos actual: \(model.vault?.name ?? ""). Pulsa para cambiar")
        .popover(isPresented: $open, arrowEdge: .top) {
            DatabaseMenu { open = false }
        }
    }

    private var subtitle: String {
        let open = model.openURLs.count
        let entries = "\(model.count(.all)) entradas"
        return open > 1 ? entries + " · \(open) abiertas" : entries
    }
}

/// Contenido del desplegable de bases de datos.
private struct DatabaseMenu: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Bases de datos")
                .font(.ui(11, .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 2)

            ForEach(Array(model.recents.enumerated()), id: \.element) { index, url in
                DatabaseMenuRow(url: url, index: index) {
                    dismiss()
                    model.switchTo(url)
                }
            }

            MenuAction(title: "Añadir base de datos…", symbol: "plus") {
                dismiss()
                model.addDatabase()
            }

            Divider().padding(.vertical, 4)

            if model.vault != nil {
                MenuAction(title: "Ajustes de esta base…", symbol: "slider.horizontal.3") {
                    dismiss()
                    model.sheet = .databaseSettings
                }
                MenuAction(title: "Recargar desde el disco", symbol: "arrow.clockwise") {
                    dismiss()
                    Task { await model.reloadFromDisk() }
                }
                MenuAction(title: "Mostrar en Finder", symbol: "folder") {
                    dismiss()
                    if let url = model.vault?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                MenuAction(title: "Cerrar esta base", symbol: "xmark.circle") {
                    dismiss()
                    model.closeDatabase()
                }
                Divider().padding(.vertical, 4)
            }

            MenuAction(title: "Bloquear todas", symbol: "lock", shortcut: "⇧⌘L") {
                dismiss()
                model.lockAll()
            }
        }
        .padding(6)
        .frame(width: 290)
    }
}

private struct DatabaseMenuRow: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let index: Int
    let action: () -> Void

    var body: some View {
        let active = model.activeURL == url
        let isOpen = model.isOpen(url)
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.ui(13, active ? .semibold : .regular))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: isOpen ? "lock.open.fill" : "lock.fill").font(.system(size: 8))
                        Text(status(isOpen: isOpen))
                    }
                    .font(.ui(11))
                    .foregroundStyle(isOpen ? Theme.green : Theme.textTertiary)
                }
                Spacer(minLength: 4)
                if active {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                } else if index < 9 {
                    Text("⌘\(index + 1)").font(.ui(11)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .buttonStyle(MenuRowStyle(height: 42))
        .accessibilityLabel("Base de datos \(url.deletingPathExtension().lastPathComponent)")
        .contextMenu {
            if isOpen && !active {
                Button("Bloquear") { model.lockBackground(url) }
            }
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Quitar de la lista", role: .destructive) { model.removeRecent(url) }
        }
    }

    private func status(isOpen: Bool) -> String {
        guard isOpen else { return "Bloqueada" }
        if let count = model.entryCount(of: url) { return "Abierta · \(count) entradas" }
        return "Abierta"
    }
}

private struct MenuAction: View {
    let title: String
    let symbol: String
    var shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) { MenuActionLabel(title: title, symbol: symbol, shortcut: shortcut) }
            .buttonStyle(MenuRowStyle())
    }
}

private struct MenuActionLabel: View {
    let title: String
    let symbol: String
    var shortcut: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26)
            Text(title).font(.ui(13)).foregroundStyle(Theme.text)
            Spacer(minLength: 4)
            if let shortcut { Text(shortcut).font(.ui(11)).foregroundStyle(Theme.textTertiary) }
        }
    }
}

/// Fila de menú con resaltado suave al pasar el ratón.
private struct MenuRowStyle: ButtonStyle {
    var height: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, height: height)
    }

    private struct RowBody: View {
        let configuration: Configuration
        let height: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Theme.selected : hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// Aviso centrado que aparece un momento al cambiar de base de datos.
struct SwitchHUD: View {
    let url: URL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.open").font(.system(size: 18)).foregroundStyle(Theme.textSecondary)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.ui(15, .semibold))
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 8)
        .allowsHitTesting(false)
        .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
    }
}
