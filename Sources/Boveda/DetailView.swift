import AppKit
import BovedaCore
import KDBXKit
import SwiftUI
import UniformTypeIdentifiers

struct EntryDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isMultiSelecting {
                MultiSelectionView()
            } else if let located = model.selectedEntry {
                EntryDetail(located: located).id(located.entry.uuid)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "key.horizontal").font(.system(size: 18)).foregroundStyle(Theme.textTertiary)
                    Text("Elige una entrada").font(.ui(13)).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
    }
}

private struct EntryDetail: View {
    @Environment(AppModel.self) private var model
    let located: LocatedEntry
    var entry: KDBX.Entry { located.entry }

    @State private var dropping = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                AuditBanner(issues: entry.excludedFromAudit ? [] : model.audit.issues(for: entry.uuid))
                if entry.excludedFromAudit {
                    Label("Excluida de la auditoría", systemImage: "shield.slash")
                        .font(.ui(12)).foregroundStyle(Theme.textTertiary)
                }

                switch entry.kind {
                case .card:
                    CardDetail(entry: entry)
                case .note:
                    if !entry.notes.isEmpty {
                        MarkdownNotes(text: entry.notes).padding(16).card()
                    }
                case .login:
                    VStack(spacing: 0) {
                        FieldRow(label: "Usuario", value: model.value(FieldKey.userName, of: entry), copyLabel: "Usuario",
                                 isReference: FieldReference.contains(entry.userName))
                        PasswordRow(password: model.value(FieldKey.password, of: entry),
                                    isReference: FieldReference.contains(entry.string(FieldKey.password)))
                        if !entry.url.isEmpty { URLRow(url: model.value(FieldKey.url, of: entry)) }
                        if let totp = TOTP.from(entry) { TOTPRow(totp: totp) }
                    }
                    .card()
                }

                let custom = entry.customFields.filter { entry.kind != .card || !CardField.all.contains($0.key) }
                if !custom.isEmpty {
                    SectionLabel("Campos personalizados")
                    VStack(spacing: 0) {
                        ForEach(custom, id: \.key) { field in
                            let raw = field.value.revealedString
                            if entry.isProtected(field.key) {
                                PasswordRow(password: model.resolved(raw), label: field.key, showStrength: false, isReference: FieldReference.contains(raw))
                            } else {
                                FieldRow(label: field.key, value: model.resolved(raw), copyLabel: field.key, isReference: FieldReference.contains(raw))
                            }
                        }
                    }
                    .card()
                }

                if !entry.notes.isEmpty && entry.kind != .note {
                    SectionLabel("Notas")
                    MarkdownNotes(text: entry.notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .card()
                }

                let tags = entry.tags.filter { $0 != favoriteTag }
                if !tags.isEmpty {
                    SectionLabel("Etiquetas")
                    FlowTags(tags: tags)
                }

                AttachmentsSection(entry: entry)

                Metadata(located: located)
            }
            .padding(20)
        }
        // Arrastrar archivos encima de la entrada los adjunta.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, !model.isInRecycleBin(entry.uuid) else { return false }
            model.addAttachments(files, to: entry.uuid)
            return true
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
                    .strokeBorder(Theme.text, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Theme.text.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
                    .overlay(Label("Suelta para adjuntar", systemImage: "paperclip").font(.ui(13, .medium)).foregroundStyle(Theme.text))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            EntryIcon(entry: entry, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? "Sin título" : entry.title)
                    .font(.ui(18, .semibold))
                    .tracking(-0.3)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(located.groupPath.dropFirst().map(\.displayName).joined(separator: " / ").ifEmpty(model.vault?.name ?? ""))
                    .font(.ui(12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            IconButton(symbol: entry.isFavorite ? "star.fill" : "star", help: entry.isFavorite ? "Quitar de favoritos" : "Añadir a favoritos", tint: entry.isFavorite ? Theme.amber : Theme.textSecondary) {
                model.toggleFavorite(entry.uuid)
            }
            PopOutButton(entryID: entry.uuid)
            Button("Editar") { model.edit(entry.uuid) }
                .buttonStyle(GButtonStyle(kind: .secondary, compact: true))
            Menu { EntryMenu(entry: entry) } label: {
                Image(systemName: "ellipsis").frame(width: 26, height: 26)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Theme.textSecondary)
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

extension View {
    func card() -> some View {
        background(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous).fill(Theme.backgroundSubtle))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.ui(12, .medium)).foregroundStyle(Theme.textSecondary).padding(.bottom, -12)
    }
}

/// Fila de un campo: etiqueta pequeña arriba y valor; al pulsar se copia.
struct FieldRow: View {
    @Environment(AppModel.self) private var model
    let label: String
    let value: String
    let copyLabel: String
    var isReference = false
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                FieldLabel(text: label, isReference: isReference)
                Text(value.isEmpty ? "—" : value)
                    .font(.ui(13))
                    .foregroundStyle(value.isEmpty ? Theme.textTertiary : Theme.text)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            Spacer()
            if !value.isEmpty {
                IconButton(symbol: "doc.on.doc", help: "Copiar \(copyLabel.lowercased())", size: 26) { model.copy(value, label: copyLabel) }
                    .opacity(hovering ? 1 : 0.55)
            }
        }
        .rowPadding()
        .background(hovering ? Theme.backgroundSubtle : .clear)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.copy(value, label: copyLabel) }
    }
}

struct PasswordRow: View {
    @Environment(AppModel.self) private var model
    let password: String
    var label = "Contraseña"
    var showStrength = true
    var isReference = false
    @State private var reveal = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    FieldLabel(text: label, isReference: isReference)
                    if reveal || model.revealPassword {
                        ColoredPassword(password: password)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    } else {
                        Text(password.isEmpty ? "—" : String(repeating: "•", count: min(max(password.count, 8), 20)))
                            .font(.mono(13))
                            .foregroundStyle(password.isEmpty ? Theme.textTertiary : Theme.text)
                    }
                }
                Spacer()
                if !password.isEmpty {
                    IconButton(symbol: reveal || model.revealPassword ? "eye.slash" : "eye", help: reveal ? "Ocultar" : "Mostrar (⇧⌘C)", size: 26) {
                        if model.revealPassword { model.revealPassword = false; reveal = false } else { reveal.toggle() }
                    }
                    IconButton(symbol: "doc.on.doc", help: "Copiar " + (label == label.uppercased() ? label : label.lowercased()), size: 26) { model.copy(password, label: label) }
                }
            }
            if showStrength && !password.isEmpty {
                // Una contraseña filtrada no es «fuerte» aunque sea larga: la barra no debe contradecir el aviso.
                if Preferences.checkBreaches, (AuditServices.shared.pwnedCount(for: password) ?? 0) > 0 {
                    StrengthBar(fraction: 0.08, label: "Filtrada · cámbiala")
                } else {
                    let strength = PasswordStrength.of(password)
                    StrengthBar(fraction: strength.fraction, label: "\(strength.label) · \(Int(PasswordStrength.bits(password))) bits")
                }
            }
        }
        .rowPadding()
        .background(hovering ? Theme.backgroundSubtle : .clear)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.copy(password, label: label) }
    }
}

/// Contraseña en monoespaciada con números y símbolos en color, para leerla sin confundir caracteres.
struct ColoredPassword: View {
    let password: String

    var body: some View {
        password.reduce(Text("")) { text, char in
            let color: Color = char.isNumber ? Theme.textSecondary : (char.isLetter ? Theme.text : Theme.red)
            return text + Text(String(char)).foregroundColor(color)
        }
        .font(.mono(13))
    }
}

struct URLRow: View {
    @Environment(AppModel.self) private var model
    let url: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Web").font(.ui(11, .medium)).foregroundStyle(Theme.textTertiary)
                Text(url).font(.ui(13)).foregroundStyle(Theme.text).underline(color: Theme.borderStrong).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            IconButton(symbol: "arrow.up.right", help: "Abrir web", size: 26) {
                if let target = URL.fromUserInput(url) { NSWorkspace.shared.open(target) }
            }
            IconButton(symbol: "doc.on.doc", help: "Copiar web", size: 26) { model.copy(url, label: "Web") }
        }
        .rowPadding()
        .background(hovering ? Theme.backgroundSubtle : .clear)
        .onHover { hovering = $0 }
    }
}

struct TOTPRow: View {
    @Environment(AppModel.self) private var model
    let totp: TOTP

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let code = totp.code(at: context.date)
            let remaining = totp.secondsRemaining(at: context.date)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Código 2FA").font(.ui(11, .medium)).foregroundStyle(Theme.textTertiary)
                    Text(Self.group(code))
                        .font(.mono(18, .medium))
                        .tracking(1)
                        .foregroundStyle(remaining <= 5 ? Theme.red : Theme.text)
                        .contentTransition(.numericText())
                }
                Spacer()
                ZStack {
                    Circle().stroke(Theme.border, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: CGFloat(remaining) / CGFloat(totp.period))
                        .stroke(remaining <= 5 ? Theme.red : Theme.text, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: remaining)
                    Text("\(remaining)").font(.ui(10, .medium)).foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
                .frame(width: 26, height: 26)
                IconButton(symbol: "doc.on.doc", help: "Copiar código", size: 26) { model.copy(code, label: "Código 2FA") }
            }
            .rowPadding()
        }
    }

    static func group(_ code: String) -> String {
        let mid = code.count / 2
        return String(code.prefix(mid)) + " " + String(code.suffix(code.count - mid))
    }
}

extension View {
    func rowPadding() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairline(.bottom)
    }
}

private struct FlowTags: View {
    let tags: [String]
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { Badge(text: $0) }
            }
        }
        .scrollIndicators(.never)
    }
}

private struct Metadata: View {
    @Environment(AppModel.self) private var model
    let located: LocatedEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack {
                    Text("Detalles").font(.ui(12, .medium)).foregroundStyle(Theme.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                let times = located.entry.times
                VStack(alignment: .leading, spacing: 6) {
                    meta("Creada", times?.creationTime)
                    meta("Modificada", times?.lastModificationTime)
                    if times?.expires == true { meta("Caduca", times?.expiryTime) }
                    meta("Contraseña cambiada", located.entry.passwordChangedDate)
                    HStack(alignment: .firstTextBaseline) {
                        Text("Versiones anteriores").font(.ui(12)).foregroundStyle(Theme.textTertiary).frame(width: 140, alignment: .leading)
                        Text("\(located.entry.history.count)").font(.ui(12)).foregroundStyle(Theme.textSecondary)
                        if !located.entry.history.isEmpty {
                            Button("Ver historial") { model.sheet = .history }
                                .buttonStyle(.plain)
                                .font(.ui(12, .medium))
                                .underline()
                        }
                    }
                    row("ID", located.entry.uuid.uuidString)
                }
            }
        }
    }

    private func meta(_ label: String, _ date: Date?) -> some View {
        row(label, date.map { $0.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "es_ES"))) } ?? "—")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.ui(12)).foregroundStyle(Theme.textTertiary).frame(width: 140, alignment: .leading)
            Text(value).font(.ui(12)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
        }
    }
}

/// Aviso de auditoría arriba de la entrada (contraseña repetida, débil o caducada).
private struct AuditBanner: View {
    let issues: [String]
    /// Rojo si la contraseña ha salido en filtraciones; naranja para lo demás.
    private var tint: Color { issues.first?.hasPrefix("Ha aparecido") == true ? Theme.red : Theme.amber }

    var body: some View {
        if !issues.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(issues, id: \.self) { Text($0).font(.ui(12, .medium)) }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.1)))
        }
    }
}

/// Adjuntos de la entrada: abrir, guardar, renombrar, quitar y añadir.
private struct AttachmentsSection: View {
    @Environment(AppModel.self) private var model
    let entry: KDBX.Entry

    var body: some View {
        let files = model.vault?.attachments(of: entry) ?? []
        let editable = !model.isInRecycleBin(entry.uuid)
        if !files.isEmpty {
            SectionLabel("Adjuntos")
            VStack(spacing: 0) {
                ForEach(files) { file in AttachmentRow(entryID: entry.uuid, file: file, editable: editable) }
            }
            .card()
        }
        if editable {
            Button { model.pickAttachments(for: entry.uuid) } label: {
                Label("Adjuntar archivo", systemImage: "paperclip")
            }
            .buttonStyle(GButtonStyle(kind: .ghost, compact: true))
            .foregroundStyle(Theme.textSecondary)
            .help("También puedes arrastrar archivos encima de la entrada")
            .padding(.top, files.isEmpty ? -8 : -10)
        }
    }
}

private struct AttachmentRow: View {
    @Environment(AppModel.self) private var model
    let entryID: UUID
    let file: Attachment
    let editable: Bool
    @State private var hovering = false
    @State private var renaming = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data))
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.ui(13)).lineLimit(1).truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.ui(11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            IconButton(symbol: "eye", help: "Abrir", size: 26) { model.openAttachment(file.name, of: entryID) }
                .opacity(hovering ? 1 : 0.55)
            IconButton(symbol: "square.and.arrow.down", help: "Guardar como…", size: 26) { model.exportAttachment(file.name, of: entryID) }
                .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(hovering ? Theme.backgroundSubtle : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.openAttachment(file.name, of: entryID) }
        .contextMenu {
            Button("Abrir") { model.openAttachment(file.name, of: entryID) }
            Button("Guardar como…") { model.exportAttachment(file.name, of: entryID) }
            if editable {
                Button("Renombrar…") { renaming = true }
                Divider()
                Button("Quitar adjunto", role: .destructive) { model.removeAttachment(file.name, from: entryID) }
            }
        }
        .sheet(isPresented: $renaming) {
            NameSheet(title: "Renombrar adjunto", placeholder: "Nombre del archivo", action: "Renombrar", initial: file.name) {
                model.renameAttachment(file.name, to: $0, in: entryID)
            }
        }
    }
}

/// Etiqueta pequeña de un campo; marca si el valor viene de otra entrada.
struct FieldLabel: View {
    let text: String
    var isReference = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.ui(11, .medium)).foregroundStyle(Theme.textTertiary)
            if isReference {
                Image(systemName: "link").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    .help("Este valor viene de otra entrada y se actualiza solo")
            }
        }
    }
}
