import BovedaCore
import KDBXKit
import SwiftUI

/// Base abierta: pestañas de cristal abajo (Contraseñas, Generador, Auditoría, Ajustes) y la búsqueda aparte.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .entries
    @State private var query = ""

    enum AppTab: Hashable { case entries, generator, audit, settings, search }

    var body: some View {
        @Bindable var model = model
        TabView(selection: $tab) {
            Tab("Contraseñas", systemImage: "key.horizontal", value: .entries) {
                EntriesTab()
            }
            Tab("Generador", systemImage: "dice", value: .generator) {
                NavigationStack { GeneratorScreen() }
            }
            Tab("Auditoría", systemImage: "checkmark.shield", value: .audit) {
                NavigationStack { AuditScreen() }
            }
            .badge(model.audit.map { auditBadge($0) } ?? 0)
            Tab("Ajustes", systemImage: "gearshape", value: .settings) {
                NavigationStack { SettingsScreen() }
            }
            Tab(value: .search, role: .search) {
                NavigationStack {
                    SearchScreen(query: query)
                        .navigationDestination(for: UUID.self) { EntryDetailView(id: $0) }
                }
                .searchable(text: $query, prompt: "Buscar en \(model.openDatabase?.name ?? "la base")")
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .toast($model.toast)
        .task(id: model.version) { model.refreshAudit() }
    }

    private func auditBadge(_ audit: Audit) -> Int {
        audit.pwned.count
    }
}

// MARK: - Lista

/// Qué se está viendo en la lista.
enum EntryFilter: Hashable {
    case all, favorites, group(UUID)
}

struct EntriesTab: View {
    @Environment(AppModel.self) private var model
    @State private var filter: EntryFilter = .all
    @State private var editing: EntryDraft?

    var body: some View {
        NavigationStack {
            EntryList(entries: entries, filter: $filter, editing: $editing)
                .navigationTitle(title)
                .navigationDestination(for: UUID.self) { EntryDetailView(id: $0) }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Bloquear", systemImage: "lock") { model.lock(manual: true) }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Nueva entrada", systemImage: "plus") { newEntry() }
                    }
                }
                .sheet(item: $editing) { EntryEditorView(draft: $0) }
        }
    }

    private var entries: [KDBX.Entry] {
        _ = model.version
        switch filter {
        case .all: return model.entries(in: nil)
        case .favorites: return model.entries(in: nil).filter(\.isFavorite)
        case let .group(id): return model.entries(in: id)
        }
    }

    private var title: String {
        switch filter {
        case .all: return "Todas"
        case .favorites: return "Favoritos"
        case let .group(id): return model.vault?.root.group(id)?.displayName ?? "Grupo"
        }
    }

    private func newEntry() {
        guard let vault = model.vault else { return }
        var group = vault.root.uuid
        if case let .group(id) = filter, id != vault.recycleBinUUID { group = id }
        editing = EntryDraft(entry: .make(title: ""), groupID: group, isNew: true)
    }
}

struct EntryList: View {
    @Environment(AppModel.self) private var model
    let entries: [KDBX.Entry]
    @Binding var filter: EntryFilter
    @Binding var editing: EntryDraft?

    var body: some View {
        List {
            Section {
                ForEach(entries, id: \.uuid) { entry in
                    NavigationLink(value: entry.uuid) { EntryRow(entry: entry) }
                        .listRowBackground(Theme.backgroundSubtle)
                        .entryActions(entry, editing: $editing)
                }
            } header: {
                GroupChips(filter: $filter)
                    .textCase(nil)
                    .listRowInsets(EdgeInsets())
                    .padding(.bottom, 6)
            }
            if entries.isEmpty {
                ContentUnavailableView(filter == .favorites ? "Sin favoritos" : "No hay entradas",
                                       systemImage: filter == .favorites ? "star" : "key.horizontal",
                                       description: Text(filter == .favorites ? "Marca una entrada con la estrella para verla aquí." : "Pulsa + para crear la primera."))
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(HushBackground())
        .animation(Theme.spring, value: entries.map(\.uuid))
        .refreshable { await model.reload() }
    }
}

/// Píldoras de grupos encima de la lista.
struct GroupChips: View {
    @Environment(AppModel.self) private var model
    @Binding var filter: EntryFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Todas", .all)
                chip("Favoritos", .favorites)
                ForEach(groups, id: \.uuid) { group in
                    chip(group.uuid == model.vault?.recycleBinUUID ? "Papelera" : group.displayName, .group(group.uuid))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private var groups: [KDBX.Group] {
        guard let vault = model.vault else { return [] }
        _ = model.version
        let bin = vault.recycleBinUUID
        var list = vault.root.flattened(excluding: bin.map { [$0] } ?? []).dropFirst().map(\.group)
        if let bin, let group = vault.root.group(bin), !group.allEntries().isEmpty { list.append(group) }
        return list
    }

    private func chip(_ title: String, _ value: EntryFilter) -> some View {
        FilterChip(title: title, selected: filter == value) {
            withAnimation(Theme.spring) { filter = value }
        }
    }
}

struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: KDBX.Entry

    var body: some View {
        HStack(spacing: 12) {
            EntryAvatar(title: entry.title, icon: model.icon(for: entry))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.title.isEmpty ? "Sin título" : entry.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if entry.isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.textTertiary)
                            .accessibilityLabel("Favorito")
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let totp = TOTP.from(entry) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    CountdownRing(fraction: Double(totp.secondsRemaining(at: context.date)) / Double(totp.period), size: 20)
                }
                .accessibilityLabel("Tiene código 2FA")
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        switch entry.kind {
        case .card: return "Tarjeta"
        case .note: return "Nota segura"
        case .login: return entry.userName.isEmpty ? (URL(string: entry.url)?.host() ?? " ") : entry.userName
        }
    }
}

extension View {
    /// Deslizar y mantener pulsado sobre una entrada: copiar, favorito, editar y borrar.
    func entryActions(_ entry: KDBX.Entry, editing: Binding<EntryDraft?>) -> some View {
        modifier(EntryActions(entry: entry, editing: editing))
    }
}

private struct EntryActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let entry: KDBX.Entry
    @Binding var editing: EntryDraft?

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading) {
                Button("Contraseña", systemImage: "doc.on.doc") { copyPassword() }
                    .tint(Theme.blue)
            }
            .swipeActions(edge: .trailing) {
                Button(inBin ? "Borrar" : "A la papelera", systemImage: "trash", role: .destructive) {
                    model.mutate { $0.deleteEntry(entry.uuid) }
                }
                Button(entry.isFavorite ? "Quitar" : "Favorito", systemImage: entry.isFavorite ? "star.slash" : "star") {
                    model.mutate { $0.toggleFavorite(entry.uuid) }
                }
                .tint(Theme.amber)
            }
            .contextMenu {
                if !entry.userName.isEmpty {
                    Button("Copiar usuario", systemImage: "person") { model.copy(entry.userName, label: "Usuario") }
                }
                if !entry.string(FieldKey.password).isEmpty {
                    Button("Copiar contraseña", systemImage: "key.horizontal") { copyPassword() }
                }
                if let totp = TOTP.from(entry) {
                    Button("Copiar código 2FA", systemImage: "clock") { model.copy(totp.code(), label: "Código") }
                }
                Divider()
                Button(entry.isFavorite ? "Quitar de favoritos" : "Añadir a favoritos", systemImage: entry.isFavorite ? "star.slash" : "star") {
                    model.mutate { $0.toggleFavorite(entry.uuid) }
                }
                Button("Editar", systemImage: "pencil") {
                    if let group = model.vault?.locate(entry.uuid)?.group.uuid {
                        editing = EntryDraft(entry: entry, groupID: group, isNew: false)
                    }
                }
                Button(inBin ? "Borrar para siempre" : "Mover a la papelera", systemImage: "trash", role: .destructive) {
                    model.mutate { $0.deleteEntry(entry.uuid) }
                }
            }
    }

    private var inBin: Bool { model.vault?.isInRecycleBin(entry.uuid) ?? false }

    private func copyPassword() {
        model.copy(model.vault?.resolve(entry.string(FieldKey.password)) ?? "", label: "Contraseña")
    }
}

// MARK: - Búsqueda

struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    let query: String
    @State private var editing: EntryDraft?

    var body: some View {
        let results = model.search(query)
        List {
            ForEach(results, id: \.uuid) { entry in
                NavigationLink(value: entry.uuid) { EntryRow(entry: entry) }
                    .listRowBackground(Theme.backgroundSubtle)
                    .entryActions(entry, editing: $editing)
            }
            if !query.isEmpty, results.isEmpty {
                ContentUnavailableView.search(text: query).listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(HushBackground())
        .navigationTitle("Buscar")
        .sheet(item: $editing) { EntryEditorView(draft: $0) }
    }
}
