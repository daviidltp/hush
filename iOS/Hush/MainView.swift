import BovedaCore
import KDBXKit
import SwiftUI

/// Base abierta: pestañas de cristal abajo (Contraseñas, Generador, Auditoría, Ajustes) y la búsqueda aparte.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: AppTab = .entries
    @State private var query = ""
    @FocusState private var searchFocused: Bool

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
                .searchFocused($searchFocused)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // Al entrar en Buscar, el teclado sale ya con la barra lista para escribir.
        .onChange(of: tab) { _, new in
            if new == .search { Task { try? await Task.sleep(for: .milliseconds(150)); searchFocused = true } }
        }
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
    @State private var creatingFolder = false
    @State private var folderName = ""

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
                        Button("Nueva carpeta", systemImage: "folder.badge.plus") { folderName = ""; creatingFolder = true }
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { newEntry() } label: {
                            Image(systemName: "plus").fontWeight(.semibold).foregroundStyle(Theme.onPrimary)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.primary)
                        .accessibilityLabel("Nueva entrada")
                    }
                }
                .sheet(item: $editing) { EntryEditorView(draft: $0) }
                .alert("Nueva carpeta", isPresented: $creatingFolder) {
                    TextField("Nombre", text: $folderName)
                    Button("Cancelar", role: .cancel) {}
                    Button("Crear") {
                        if let id = model.createFolder(named: folderName, in: currentGroup) {
                            withAnimation(Theme.spring) { filter = .group(id) }
                        }
                    }
                } message: {
                    Text(currentGroup.flatMap { model.vault?.root.group($0)?.displayName }.map { "Dentro de «\($0)»." } ?? "")
                }
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

    /// Carpeta que se está viendo (donde se crean entradas y carpetas nuevas).
    private var currentGroup: UUID? {
        if case let .group(id) = filter, id != model.vault?.recycleBinUUID { return id }
        return nil
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
                .listRowSeparator(.hidden)
                        .entryActions(entry, editing: $editing)
                }
            } header: {
                GroupChips(filter: $filter)
                    .textCase(nil)
                    .listRowInsets(EdgeInsets())
                    .padding(.top, 4)
                    .padding(.bottom, 14)
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
    @State private var renaming: UUID?
    @State private var deleting: UUID?
    @State private var newName = ""

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Todas", .all)
                chip("Favoritos", .favorites)
                ForEach(groups, id: \.uuid) { group in
                    let isBin = group.uuid == model.vault?.recycleBinUUID
                    chip(isBin ? "Papelera" : group.displayName, .group(group.uuid))
                        .contextMenu {
                            if !isBin {
                                Button("Renombrar", systemImage: "pencil") { newName = group.name ?? ""; renaming = group.uuid }
                                Button("Borrar carpeta", systemImage: "trash", role: .destructive) { deleting = group.uuid }
                            }
                        }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .onChange(of: filter) { _, new in withAnimation(Theme.spring) { proxy.scrollTo(new, anchor: .center) } }
        }
        .alert("Renombrar carpeta", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nombre", text: $newName)
            Button("Cancelar", role: .cancel) {}
            Button("Guardar") { if let id = renaming { model.renameFolder(id, to: newName) } }
        }
        .confirmationDialog("¿Borrar la carpeta?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Borrar", role: .destructive) {
                guard let id = deleting else { return }
                if filter == .group(id) { filter = .all }
                model.deleteFolder(id)
            }
        } message: {
            Text("Se mueve a la papelera con todo lo que tiene dentro.")
        }
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
        .id(value)
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
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.amber)
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
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let results = model.search(query)
        let recents = searching ? [] : model.recentEntries
        let favorites = searching ? [] : model.entries(in: nil).filter { $0.isFavorite && !recents.map(\.uuid).contains($0.uuid) }
        List {
            if searching {
                rows(results)
                if results.isEmpty {
                    ContentUnavailableView.search(text: query).listRowBackground(Color.clear)
                }
            } else if recents.isEmpty && favorites.isEmpty {
                ContentUnavailableView("Busca en tus contraseñas", systemImage: "magnifyingglass",
                                       description: Text("Por nombre, usuario, web, notas o etiquetas."))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .padding(.top, 60)
            } else {
                if !recents.isEmpty {
                    Section { rows(recents) } header: { header("Recientes") }
                }
                if !favorites.isEmpty {
                    Section { rows(favorites) } header: { header("Favoritos") }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 12, for: .scrollContent)
        .background(HushBackground())
        .navigationTitle("Buscar")
        .sheet(item: $editing) { EntryEditorView(draft: $0) }
    }

    private func rows(_ entries: [KDBX.Entry]) -> some View {
        ForEach(entries, id: \.uuid) { entry in
            NavigationLink(value: entry.uuid) { EntryRow(entry: entry) }
                .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)
                .entryActions(entry, editing: $editing)
        }
    }

    private func header(_ text: String) -> some View {
        ListHeader(text)
    }
}
