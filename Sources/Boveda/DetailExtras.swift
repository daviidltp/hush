import AppKit
import BovedaCore
import KDBXKit
import SwiftUI

// MARK: - Tarjeta

/// Tarjeta de crédito: un dibujo de la tarjeta y debajo cada dato con su botón de copiar.
struct CardDetail: View {
    @Environment(AppModel.self) private var model
    let entry: KDBX.Entry

    private func field(_ key: String) -> String { model.resolved(entry.string(key)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CardArt(holder: field(CardField.holder), number: field(CardField.number), expiry: field(CardField.expiry), title: entry.title)
            VStack(spacing: 0) {
                PasswordRow(password: field(CardField.number), label: "Número", showStrength: false)
                FieldRow(label: "Titular", value: field(CardField.holder), copyLabel: "Titular")
                FieldRow(label: "Caducidad", value: field(CardField.expiry), copyLabel: "Caducidad")
                PasswordRow(password: field(CardField.cvv), label: "CVV", showStrength: false)
                if !field(CardField.pin).isEmpty { PasswordRow(password: field(CardField.pin), label: "PIN", showStrength: false) }
            }
            .card()
        }
    }
}

struct CardArt: View {
    let holder: String
    let number: String
    let expiry: String
    let title: String

    private var brand: String {
        let digits = number.filter(\.isNumber)
        if digits.hasPrefix("4") { return "VISA" }
        if let two = Int(digits.prefix(2)), (51...55).contains(two) || (22...27).contains(two) { return "Mastercard" }
        if digits.hasPrefix("34") || digits.hasPrefix("37") { return "AMEX" }
        return ""
    }

    var body: some View {
        let digits = number.filter(\.isNumber)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title.isEmpty ? "Tarjeta" : title).font(.ui(13, .semibold))
                Spacer()
                Text(brand).font(.system(size: 13, weight: .heavy, design: .rounded)).italic()
            }
            Spacer()
            Text("••••  ••••  ••••  " + (digits.count >= 4 ? String(digits.suffix(4)) : "••••"))
                .font(.mono(17, .medium))
                .tracking(1)
            Spacer().frame(height: 14)
            HStack(alignment: .bottom) {
                Text(holder.isEmpty ? " " : holder.uppercased()).font(.ui(11, .medium)).lineLimit(1)
                Spacer()
                if !expiry.isEmpty { Text(expiry).font(.mono(12)) }
            }
            .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: 340, minHeight: 190, maxHeight: 200)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Theme.dynamic(light: 0x2A2A2A, dark: 0x3C3C3C), Theme.dynamic(light: 0x080808, dark: 0x262626)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

// MARK: - Notas con formato

/// Notas con Markdown sencillo: títulos (#), listas (- o *), casillas (- [ ] / - [x]), **negrita**, *cursiva*, `código` y enlaces.
struct MarkdownNotes: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 4)
        } else if let level = heading(trimmed) {
            inline(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                .font(.ui(level == 1 ? 17 : level == 2 ? 15 : 13, .semibold))
                .padding(.top, 4)
        } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: trimmed.hasPrefix("- [ ] ") ? "square" : "checkmark.square.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                inline(String(trimmed.dropFirst(6))).font(.ui(13))
            }
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(Theme.textSecondary)
                inline(String(trimmed.dropFirst(2))).font(.ui(13))
            }
            .padding(.leading, CGFloat(line.prefix { $0 == " " }.count / 2) * 12)
        } else if trimmed.hasPrefix("> ") {
            inline(String(trimmed.dropFirst(2)))
                .font(.ui(13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.borderStrong).frame(width: 2) }
        } else {
            inline(line).font(.ui(13))
        }
    }

    private func heading(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...3).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}

// MARK: - Varias seleccionadas

struct MultiSelectionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = model.selectedIDs
        let entries = ids.compactMap { model.vault?.locate($0)?.entry }
        let allFavorite = entries.allSatisfy(\.isFavorite)
        VStack(spacing: 18) {
            ZStack {
                ForEach(Array(entries.prefix(3).enumerated().reversed()), id: \.offset) { offset, entry in
                    EntryIcon(entry: entry, size: 48)
                        .rotationEffect(.degrees(Double(offset) * 8 - 8))
                        .offset(x: CGFloat(offset) * 14 - 14)
                }
            }
            .frame(height: 60)
            VStack(spacing: 4) {
                Text("\(ids.count) entradas seleccionadas").font(.ui(17, .semibold))
                Text("⌘ clic para añadir o quitar · ⇧ clic para elegir un rango").font(.ui(12)).foregroundStyle(Theme.textTertiary)
            }
            VStack(spacing: 8) {
                if let root = model.root {
                    Menu {
                        ForEach(root.flattened(excluding: model.vault?.excludedFromBrowsing ?? []), id: \.group.uuid) { item in
                            Button(String(repeating: "   ", count: item.level) + item.group.displayName) { model.moveSelection(to: item.group.uuid) }
                        }
                    } label: {
                        Label("Mover a…", systemImage: "folder").frame(maxWidth: .infinity)
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(GButtonStyle(kind: .secondary))
                }
                Button { model.setFavorite(!allFavorite, for: ids) } label: {
                    Label(allFavorite ? "Quitar de favoritos" : "Añadir a favoritos", systemImage: allFavorite ? "star.slash" : "star")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GButtonStyle(kind: .secondary))
                Button { model.export(only: Set(ids), withAttachments: false) } label: {
                    Label("Exportar a CSV…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(GButtonStyle(kind: .secondary))
                Button(role: .destructive) { model.deleteSelection() } label: {
                    Label(model.deleteTitle(for: ids), systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GButtonStyle(kind: .danger))
            }
            .frame(width: 240)
            Button("Quitar la selección") { model.selectedEntryID = ids.first }
                .buttonStyle(.plain)
                .font(.ui(12))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Ventana aparte

struct PopOutTarget: Codable, Hashable {
    let entryID: UUID
    let vault: URL
}

struct PopOutButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let entryID: UUID

    var body: some View {
        IconButton(symbol: "macwindow.on.rectangle", help: "Abrir en otra ventana (⌥⌘O)") {
            guard let url = model.vault?.url else { return }
            openWindow(id: "entry", value: PopOutTarget(entryID: entryID, vault: url))
        }
    }
}

/// Una entrada en su propia ventana pequeña. Con la chincheta se queda encima de todo.
struct PopOutEntryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: PopOutTarget
    @State private var pinned = false
    @State private var window: NSWindow?

    var body: some View {
        let vault = model.openVault(target.vault)
        let entry = vault?.locate(target.entryID)?.entry
        VStack(alignment: .leading, spacing: 14) {
            if let vault, let entry {
                HStack(spacing: 10) {
                    EntryIcon(entry: entry, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title.isEmpty ? "Sin título" : entry.title).font(.ui(15, .semibold)).lineLimit(1)
                        Text(vault.name).font(.ui(11)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    IconButton(symbol: pinned ? "pin.fill" : "pin", help: pinned ? "Dejar de fijar" : "Fijar encima de todo",
                               tint: pinned ? Theme.text : Theme.textSecondary) {
                        pinned.toggle()
                        window?.level = pinned ? .floating : .normal
                    }
                }
                switch entry.kind {
                case .card:
                    CardDetail(entry: entry)
                case .note:
                    ScrollView { MarkdownNotes(text: entry.notes) }.padding(14).card()
                case .login:
                    VStack(spacing: 0) {
                        FieldRow(label: "Usuario", value: vault.resolve(entry.userName), copyLabel: "Usuario")
                        PasswordRow(password: vault.resolve(entry.string(FieldKey.password)), showStrength: false)
                        if !entry.url.isEmpty { URLRow(url: vault.resolve(entry.url)) }
                        if let totp = TOTP.from(entry) { TOTPRow(totp: totp) }
                    }
                    .card()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "lock").font(.system(size: 20)).foregroundStyle(Theme.textTertiary)
                    Text("La base está bloqueada").font(.ui(13, .medium))
                    Button("Cerrar") { dismiss() }.buttonStyle(GButtonStyle(kind: .secondary, compact: true))
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(Theme.background)
        .background(WindowReader { window = $0 })
    }
}

// MARK: - Historial

struct HistorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int?
    @State private var reveal = false
    @State private var confirmDelete = false

    var body: some View {
        let entry = model.selectedEntry?.entry
        let history = entry?.history ?? []
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Historial").font(.ui(18, .semibold))
                    Text(entry?.title ?? "").font(.ui(12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                IconButton(symbol: "xmark", help: "Cerrar", size: 28) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)

            if let entry, !history.isEmpty {
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(history.indices.reversed(), id: \.self) { index in
                                let newer = index + 1 < history.count ? history[index + 1] : entry
                                Button { selected = index } label: {
                                    VersionRow(version: history[index], changes: history[index].changes(to: newer), selected: selected == index)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selected == index ? .isSelected : [])
                            }
                        }
                        .padding(10)
                    }
                    .frame(width: 250)
                    .background(Theme.backgroundSubtle)

                    Divider()

                    if let index = selected, history.indices.contains(index) {
                        VersionDetail(entry: entry, index: index, reveal: $reveal) {
                            model.restoreHistory(index, of: entry.uuid)
                            selected = nil
                        } onDelete: {
                            confirmDelete = true
                        }
                        .confirmationDialog("¿Borrar esta versión del historial?", isPresented: $confirmDelete) {
                            Button("Borrar versión", role: .destructive) {
                                model.deleteHistory(index, of: entry.uuid)
                                selected = nil
                            }
                        }
                    } else {
                        Text("Elige una versión para ver qué cambió")
                            .font(.ui(13)).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .hairline(.top)
            } else {
                Text("Esta entrada no tiene versiones anteriores.")
                    .font(.ui(13)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 760, height: 520)
        .background(Theme.background)
        .onAppear { selected = history.indices.last }
    }
}

private struct VersionRow: View {
    let version: KDBX.Entry
    let changes: [FieldChange]
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(version.modified.map { $0.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "es_ES"))) } ?? "Sin fecha")
                .font(.ui(13, .medium))
            Text(changes.isEmpty ? "Sin cambios en los campos" : "Después cambió: " + changes.map(\.label).joined(separator: ", "))
                .font(.ui(11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.selected : .clear))
        .contentShape(Rectangle())
    }
}

/// Lo que tenía la versión elegida frente a la actual, con botón para volver a ella.
private struct VersionDetail: View {
    let entry: KDBX.Entry
    let index: Int
    @Binding var reveal: Bool
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let version = entry.history[index]
        let changes = version.changes(to: entry)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Diferencias con la versión actual").font(.ui(13, .semibold))
                Spacer()
                if changes.contains(where: \.secret) {
                    Toggle("Mostrar contraseñas", isOn: $reveal).toggleStyle(.switch).controlSize(.mini).font(.ui(12))
                }
            }
            ScrollView {
                VStack(spacing: 10) {
                    if changes.isEmpty {
                        Text("Es igual que la actual.").font(.ui(13)).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(changes) { change in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(change.label).font(.ui(11, .medium)).foregroundStyle(Theme.textTertiary)
                            diffLine("Antes", change.old, secret: change.secret, tint: Theme.red)
                            diffLine("Ahora", change.new, secret: change.secret, tint: Theme.green)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                    }
                }
            }
            HStack {
                Button("Borrar versión", role: .destructive, action: onDelete)
                    .buttonStyle(GButtonStyle(kind: .ghost, compact: true))
                    .foregroundStyle(Theme.red)
                Spacer()
                Button("Restaurar esta versión", action: onRestore)
                    .buttonStyle(GButtonStyle(kind: .primary))
                    .disabled(changes.isEmpty)
            }
        }
        .padding(18)
    }

    private func diffLine(_ label: String, _ value: String, secret: Bool, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.ui(11, .medium)).foregroundStyle(tint).frame(width: 40, alignment: .leading)
            Group {
                if value.isEmpty {
                    Text("vacío").foregroundStyle(Theme.textTertiary)
                } else if secret && !reveal {
                    Text(String(repeating: "•", count: min(max(value.count, 8), 20)))
                } else {
                    Text(value)
                }
            }
            .font(secret ? .mono(12) : .ui(12))
            .textSelection(.enabled)
            .lineLimit(4)
        }
    }
}
