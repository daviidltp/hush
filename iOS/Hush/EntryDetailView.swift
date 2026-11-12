import BovedaCore
import KDBXKit
import SwiftUI

/// Detalle de una entrada. Tocar un campo lo copia; los secretos van ocultos hasta pulsar el ojo.
struct EntryDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var editing: EntryDraft?
    @State private var showHistory = false
    @State private var confirmDelete = false

    var body: some View {
        _ = model.version
        return Group {
            if let located = model.vault?.locate(id) {
                content(located)
            } else {
                ContentUnavailableView("Entrada borrada", systemImage: "trash")
            }
        }
        .background(HushBackground())
        .onAppear { model.noteOpened(id) }
    }

    private func content(_ located: LocatedEntry) -> some View {
        let entry = located.entry
        let vault = model.vault
        let inBin = vault?.isInRecycleBin(id) ?? false
        return ScrollView {
            VStack(spacing: 16) {
                header(entry, group: located.group)
                fields(entry)
                if !entry.notes.isEmpty {
                    VStack(spacing: 6) {
                        SectionLabel(text: "Notas")
                        Card {
                            Text(entry.notes)
                                .font(.body)
                                .foregroundStyle(Theme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }
                    }
                }
                if let vault, entry.hasAttachments {
                    VStack(spacing: 6) {
                        SectionLabel(text: "Adjuntos")
                        Card {
                            ForEach(Array(vault.attachments(of: entry).enumerated()), id: \.element.id) { index, file in
                                HStack {
                                    Image(systemName: "paperclip").foregroundStyle(Theme.textSecondary)
                                    Text(file.name).lineLimit(1)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                        .font(.footnote).foregroundStyle(Theme.textTertiary)
                                }
                                .padding(16)
                            }
                        }
                    }
                }
                metadata(entry)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 120)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(entry.isFavorite ? "Quitar de favoritos" : "Favorito", systemImage: entry.isFavorite ? "star.fill" : "star") {
                    model.mutate { $0.toggleFavorite(id) }
                }
                .tint(entry.isFavorite ? Theme.amber : Theme.text)
                .sensoryFeedback(.selection, trigger: entry.isFavorite)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Más", systemImage: "ellipsis") {
                    if !entry.history.isEmpty {
                        Button("Historial (\(entry.history.count))", systemImage: "clock.arrow.circlepath") { showHistory = true }
                    }
                    if inBin {
                        Button("Restaurar", systemImage: "arrow.uturn.backward") { model.mutate { $0.restoreFromRecycleBin(id) } }
                    }
                    Button(inBin ? "Borrar para siempre" : "Mover a la papelera", systemImage: "trash", role: .destructive) {
                        if inBin { confirmDelete = true } else {
                            model.mutate { $0.deleteEntry(id) }
                            dismiss()
                        }
                    }
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Editar") { editing = EntryDraft(entry: entry, groupID: located.group.uuid, isNew: false) }
            }
        }
        .sheet(item: $editing) { EntryEditorView(draft: $0) }
        .sheet(isPresented: $showHistory) { HistorySheet(id: id) }
        .confirmationDialog("¿Borrar para siempre?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Borrar", role: .destructive) {
                model.mutate { $0.deleteEntry(id) }
                dismiss()
            }
        } message: {
            Text("No se puede deshacer.")
        }
    }

    private func header(_ entry: KDBX.Entry, group: KDBX.Group) -> some View {
        VStack(spacing: 6) {
            EntryAvatar(title: entry.title, icon: model.icon(for: entry), size: 68)
                .padding(.bottom, 6)
            Text(entry.title.isEmpty ? "Sin título" : entry.title)
                .font(.title2.weight(.bold))
                .tracking(-0.3)
                .multilineTextAlignment(.center)
            Text([URL(string: entry.url)?.host(), group.uuid == model.vault?.root.uuid ? nil : group.displayName].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    @ViewBuilder private func fields(_ entry: KDBX.Entry) -> some View {
        let resolve: (String) -> String = { model.vault?.resolve($0) ?? $0 }
        let password = resolve(entry.string(FieldKey.password))
        let totp = TOTP.from(entry)
        let rows: [FieldRow.Model] = {
            var list: [FieldRow.Model] = []
            if entry.kind == .card {
                for key in CardField.all where !entry.string(key).isEmpty {
                    list.append(.init(label: key, value: entry.string(key), secret: CardField.secret.contains(key)))
                }
            }
            if !entry.userName.isEmpty { list.append(.init(label: "Usuario", value: resolve(entry.userName))) }
            if !password.isEmpty { list.append(.init(label: "Contraseña", value: password, secret: true, strength: true)) }
            return list
        }()
        let custom = entry.customFields.filter { entry.kind != .card || !CardField.all.contains($0.key) }

        if !rows.isEmpty || totp != nil || !entry.url.isEmpty {
            Card {
                ForEach(Array(rows.enumerated()), id: \.element.label) { index, row in
                    FieldRow(model: row)
                }
                if let totp {
                    TOTPRow(totp: totp)
                }
                if !entry.url.isEmpty {
                    URLRow(url: entry.url)
                }
            }
        }
        if !custom.isEmpty {
            VStack(spacing: 6) {
                SectionLabel(text: "Otros campos")
                Card {
                    ForEach(Array(custom.enumerated()), id: \.element.key) { index, field in
                        FieldRow(model: .init(label: field.key, value: resolve(field.value.revealedString), secret: entry.isProtected(field.key)))
                    }
                }
            }
        }
    }

    private func metadata(_ entry: KDBX.Entry) -> some View {
        VStack(spacing: 4) {
            if let modified = entry.modified {
                Text("Modificada el \(modified.formatted(date: .long, time: .shortened))")
            }
            if let created = entry.times?.creationTime {
                Text("Creada el \(created.formatted(date: .long, time: .omitted))")
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.textTertiary)
        .padding(.top, 8)
    }
}

/// Fila de un campo: etiqueta encima, valor debajo. Tocarla copia el valor.
struct FieldRow: View {
    struct Model {
        let label: String
        let value: String
        var secret = false
        var strength = false
    }

    @Environment(AppModel.self) private var app
    let model: Model
    @State private var revealed = false

    var body: some View {
        Button { app.copy(model.value, label: model.label) } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.label)
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                    Text(model.secret && !revealed ? String(repeating: "•", count: min(max(model.value.count, 8), 16)) : model.value)
                        .font(model.secret ? .mono(.body) : .body)
                        .foregroundStyle(Theme.text)
                        .lineLimit(revealed ? nil : 1)
                        .multilineTextAlignment(.leading)
                        .contentTransition(.opacity)
                    if model.strength {
                        let strength = PasswordStrengthInfo(model.value)
                        MeterBar(fraction: strength.fraction, tint: Theme.strengthColor(strength.fraction))
                            .padding(.top, 4)
                            .accessibilityLabel("Fortaleza: \(strength.label)")
                    }
                }
                Spacer(minLength: 0)
                if model.secret {
                    Button { withAnimation(Theme.spring) { revealed.toggle() } } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel(revealed ? "Ocultar" : "Mostrar")
                }
                Image(systemName: "doc.on.doc")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .accessibilityHint("Toca para copiar")
    }
}

/// Código 2FA en vivo con el anillo de los segundos que quedan.
struct TOTPRow: View {
    @Environment(AppModel.self) private var app
    let totp: TOTP

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let code = totp.code(at: context.date)
            Button { app.copy(code, label: "Código") } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Código 2FA").font(.footnote).foregroundStyle(Theme.textTertiary)
                        Text(Self.grouped(code))
                            .font(.mono(.title2, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    CountdownRing(fraction: Double(totp.secondsRemaining(at: context.date)) / Double(totp.period))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .animation(Theme.spring, value: code)
            }
            .buttonStyle(RowPressStyle())
            .accessibilityLabel("Código 2FA \(code)")
            .accessibilityHint("Toca para copiar")
        }
    }

    static func grouped(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let half = code.count / 2
        return code.prefix(half) + " " + code.suffix(half)
    }
}

struct URLRow: View {
    @Environment(AppModel.self) private var app
    let url: String

    var body: some View {
        HStack {
            Button { app.copy(url, label: "Web") } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Web").font(.footnote).foregroundStyle(Theme.textTertiary)
                    Text(url).font(.body).foregroundStyle(Theme.text).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let link = URL(string: url.contains("://") ? url : "https://" + url), link.scheme?.hasPrefix("http") == true {
                Link(destination: link) {
                    Image(systemName: "arrow.up.right")
                        .frame(width: 36, height: 36)
                }
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel("Abrir web")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Fila que se ilumina al tocarla (respuesta inmediata, sin esperar a soltar).
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.selected : .clear)
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.25), value: configuration.isPressed)
    }
}

/// Versiones anteriores de una entrada, con restaurar.
struct HistorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: UUID

    var body: some View {
        NavigationStack {
            List {
                if let entry = model.vault?.locate(id)?.entry {
                    ForEach(Array(entry.history.enumerated()).reversed(), id: \.offset) { index, old in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(old.modified?.formatted(date: .abbreviated, time: .shortened) ?? "Versión \(index + 1)")
                                .font(.body.weight(.medium))
                            Text(old.changes(to: entry).map(\.label).joined(separator: ", ").nonEmpty ?? "Sin cambios visibles")
                                .font(.footnote).foregroundStyle(Theme.textSecondary)
                        }
                        .listRowBackground(Theme.backgroundSubtle)
                        .listRowSeparator(.hidden)
                        .swipeActions {
                            Button("Restaurar", systemImage: "arrow.uturn.backward") {
                                model.mutate { $0.restoreHistory(index, of: id) }
                                dismiss()
                            }
                            .tint(Theme.blue)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Historial")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo", systemImage: "checkmark") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.background)
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
