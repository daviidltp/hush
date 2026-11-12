import AppKit
import BovedaCore
import KDBXKit
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focus: FocusArea?
    @State private var showGenerator = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .focused($focus, equals: .groups)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } content: {
            EntryListView(focus: $focus)
                .navigationSplitViewColumnWidth(min: 340, ideal: 480)
        } detail: {
            EntryDetailView()
                .navigationSplitViewColumnWidth(min: 340, ideal: 420)
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Buscar")
        .toolbarBackground(colorScheme == .dark ? Theme.background : Color.clear, for: .windowToolbar)
        .toolbarBackgroundVisibility(colorScheme == .dark ? .visible : .automatic, for: .windowToolbar)
        .searchFocused($focus, equals: .search)
        .focusedSceneValue(\.browserFocus, focus)
        .toolbar(id: "principal") { mainToolbar }
        .onChange(of: model.searchFocusTrigger) { focus = .search }
        .onChange(of: model.focusRequest) { _, request in
            guard let request else { return }
            focus = request
            model.focusRequest = nil
        }
        .onChange(of: model.search) { _, _ in
            let list = model.visibleEntries
            if !list.contains(where: { $0.uuid == model.selectedEntryID }) { model.selectedEntryID = list.first?.uuid }
        }
        .sheet(item: $model.editing) { draft in EntryEditorView(draft: draft) }
        .sheet(item: $model.sheet) { kind in sheetView(kind) }
    }

    // La barra y las hojas van aparte: en un solo `body` el compilador de Swift 6.1 no termina de comprobar los tipos.

    private var copyName: String { (model.selectedEntry?.entry.kind ?? .login).mainValueName }

    /// Barra personalizable: clic derecho → "Personalizar barra de herramientas…".
    @ToolbarContentBuilder
    private var mainToolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "guardado", placement: .navigation) {
            SaveIndicator()
        }
        ToolbarItem(id: "pestanas", placement: .principal) {
            DatabaseTabs()
        }
        ToolbarItem(id: "generador", placement: .primaryAction) {
            Button { showGenerator.toggle() } label: { Label("Generador", systemImage: "dice") }
                .help("Generador de contraseñas")
                .popover(isPresented: $showGenerator, arrowEdge: .bottom) { GeneratorView(onUse: nil).frame(width: 340) }
        }
        ToolbarItem(id: "informe", placement: .primaryAction, showsByDefault: false) {
            Button { model.sheet = .report } label: { Label("Informe", systemImage: "chart.bar.doc.horizontal") }
                .help("Informe de contraseñas (⇧⌘R)")
        }
        ToolbarItem(id: "copiar", placement: .primaryAction, showsByDefault: false) {
            Button { model.copyPassword() } label: { Label(L("Copiar ") + copyName, systemImage: "key") }
                .help("Copiar \(copyName) (⌘C)")
                .disabled(model.selectedEntry == nil)
        }
        actionItems
    }

    @ToolbarContentBuilder
    private var actionItems: some CustomizableToolbarContent {
        ToolbarItem(id: "abrirweb", placement: .primaryAction, showsByDefault: false) {
            Button { if let e = model.selectedEntry?.entry { model.copyPasswordAndOpenURL(e) } } label: { Label("Contraseña y web", systemImage: "safari") }
                .help("Copiar contraseña y abrir la web (⌥⌘U)")
                .disabled(model.selectedEntry == nil)
        }
        ToolbarItem(id: "rapida", placement: .primaryAction, showsByDefault: false) {
            Button { QuickSearchPanel.show() } label: { Label("Búsqueda rápida", systemImage: "magnifyingglass.circle") }
                .help("Búsqueda rápida")
        }
        ToolbarItem(id: "ajustesbase", placement: .primaryAction, showsByDefault: false) {
            Button { model.sheet = .databaseSettings } label: { Label("Ajustes de la base", systemImage: "slider.horizontal.3") }
                .help("Ajustes de la base de datos (⇧⌘,)")
        }
        ToolbarItem(id: "bloquear", placement: .primaryAction) {
            Button { model.lock() } label: { Label("Bloquear", systemImage: "lock") }
                .help("Bloquear (⌘L)")
        }
        ToolbarItem(id: "grupo", placement: .primaryAction) {
            Button { model.requestNewGroup() } label: { Label("Nuevo grupo", systemImage: "folder.badge.plus") }
                .help("Nuevo grupo (⌥⌘N)")
        }
        ToolbarItem(id: "nueva", placement: .primaryAction) {
            Menu {
                ForEach(EntryKind.allCases, id: \.self) { kind in
                    Button { model.newEntry(kind) } label: { Label(kind.label, systemImage: kind.symbol) }
                }
            } label: {
                Label("Nueva entrada", systemImage: "plus")
            } primaryAction: {
                model.newEntry()
            }
            .accessibilityLabel("Nueva entrada")
            .help("Nueva entrada (⌘N) · mantén pulsado para tarjeta o nota")
        }
    }

    @ViewBuilder
    private func sheetView(_ kind: AppModel.SheetKind) -> some View {
        switch kind {
        case .shortcuts: ShortcutsSheet()
        case .report: ReportSheet()
        case .databaseSettings: DatabaseSettingsSheet()
        case .totp: TOTPSheet()
        case .history: HistorySheet()
        case .emergencyKit: EmergencyKitSheet()
        case .newGroup:
            NameSheet(title: model.newGroupParent.flatMap { model.root?.group($0)?.displayName }.map { L("Nuevo grupo en \($0)") } ?? L("Nuevo grupo"),
                      placeholder: L("Nombre del grupo"), action: L("Crear")) { model.addGroup(named: $0, in: model.newGroupParent) }
        }
    }
}

// MARK: - Indicador de guardado

private struct SaveIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            switch model.saveState {
            case .saving:
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
            case .saved:
                Circle().fill(Theme.green).frame(width: 7, height: 7).frame(width: 12, height: 12)
            case .failed:
                Circle().fill(Theme.red).frame(width: 7, height: 7).frame(width: 12, height: 12)
            }
            // Ancho fijo: al pasar de «Guardado» a «Guardando…» no se mueven los botones de al lado.
            Text(text).font(.ui(12)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .help(failureReason ?? model.vault?.url.path ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityValue(failureReason ?? "")
        .animation(.easeOut(duration: 0.15), value: model.saveState)
    }

    /// El motivo completo de un fallo al guardar, para el tooltip y VoiceOver.
    var failureReason: String? {
        if case let .failed(reason) = model.saveState { return reason }
        return nil
    }

    var text: String {
        switch model.saveState {
        case .saved: return L("Guardado")
        case .saving: return L("Guardando…")
        case .failed: return L("Sin guardar")
        }
    }
}

// MARK: - Barra lateral nativa

/// Lista de bases de datos: la activa, las abiertas en segundo plano y las bloqueadas.
private struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let selection = Binding<SidebarItem?>(
            get: { model.sidebar },
            set: { item in
                guard let item, item != model.sidebar else { return }
                model.sidebar = item
                model.search = ""
                model.selectedEntryID = model.visibleEntries.first?.uuid
            }
        )
        List(selection: selection) {
            Section("Vista rápida") {
                SidebarLabel(item: .all, title: L("Todas las entradas"), symbol: "tray.full")
                SidebarLabel(item: .favorites, title: L("Favoritos"), symbol: "star")
                SidebarLabel(item: .twoFactor, title: L("Códigos 2FA"), symbol: "clock.badge.checkmark")
                if model.count(.passkeys) > 0 {
                    SidebarLabel(item: .passkeys, title: L("Claves de acceso"), symbol: "person.badge.key")
                }
                if model.count(.attachments) > 0 {
                    SidebarLabel(item: .attachments, title: L("Adjuntos"), symbol: "paperclip")
                }
                if model.count(.expired) > 0 {
                    SidebarLabel(item: .expired, title: L("Caducadas"), symbol: "calendar.badge.exclamationmark")
                }
            }

            Section {
                if let root = model.root {
                    ForEach(root.groups.filter { $0.uuid != model.vault?.recycleBinUUID }, id: \.uuid) { group in
                        GroupNode(group: group)
                    }
                }
            } header: {
                // El «+» va pegado al título y no al borde: macOS pone ahí su chevron de mostrar/ocultar
                // al pasar el ratón, encoge la cabecera y el «+» saltaba aunque la sección no sea plegable.
                HStack(spacing: 2) {
                    Text("Grupos")
                    Button { model.requestNewGroup(in: model.root?.uuid) } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Nuevo grupo (⌥⌘N)")
                    .accessibilityLabel("Nuevo grupo")
                    Spacer(minLength: 0)
                }
            }
            .collapsible(false)

            let tags = model.vault?.allTags ?? []
            if !tags.isEmpty {
                Section("Etiquetas") {
                    ForEach(tags, id: \.self) { tag in
                        SidebarLabel(item: .tag(tag), title: tag, symbol: "number")
                    }
                }
            }

            if model.vault?.recycleBinUUID != nil {
                Section {
                    let trashed = model.vault?.recycleBinUUID.flatMap { model.root?.group($0) }?.groups ?? []
                    let bin = SidebarLabel(item: .recycleBin, title: L("Papelera"), symbol: "trash")
                        .contextMenu { Button("Vaciar papelera…", role: .destructive) { model.confirmEmptyRecycleBin() } }
                    // Los grupos borrados se ven dentro de la papelera para poder restaurarlos.
                    if trashed.isEmpty {
                        bin
                    } else {
                        DisclosureGroup {
                            ForEach(trashed, id: \.uuid) { GroupNode(group: $0) }
                        } label: { bin }
                    }
                }
            }

            Section("Auditoría") {
                if Preferences.checkBreaches { AuditLabel(kind: .pwned, title: L("Filtradas")) }
                AuditLabel(kind: .duplicates, title: L("Repetidas"))
                AuditLabel(kind: .similar, title: L("Parecidas"))
                AuditLabel(kind: .weak, title: L("Débiles"))
                if Preferences.check2FA { AuditLabel(kind: .missing2FA, title: L("Sin 2FA")) }
                AuditLabel(kind: .all, title: L("Todos los problemas"))
            }
        }
        .listStyle(.sidebar)
        // Filas más altas y más aire entre secciones: la barra lateral respiraba poco.
        .environment(\.sidebarRowSize, .large)
        .contextMenu {
            Button("Nuevo grupo") { model.requestNewGroup(in: model.root?.uuid) }
        }
        .scrollContentBackground(colorScheme == .dark ? .hidden : .automatic)
        .background(colorScheme == .dark ? Theme.background : .clear)
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
    }
}

private struct SidebarLabel: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .lineLimit(1)
            .badge(model.count(item))
            .accessibilityLabel(title)
            .accessibilityValue(model.count(item) > 0 ? "\(model.count(item))" : "")
            .tag(item)
            .dropDestination(for: String.self) { items, _ in
                guard case let .group(groupID) = item else { return false }
                for text in items { if let id = UUID(uuidString: text) { model.move(id, to: groupID) } }
                return true
            }
    }
}

private struct GroupNode: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: KDBX.Group
    @State private var expanded = true
    @State private var renaming = false

    var body: some View {
        Group {
            if group.groups.isEmpty {
                label
            } else {
                DisclosureGroup(isExpanded: toggle) {
                    ForEach(group.groups, id: \.uuid) { GroupNode(group: $0) }
                } label: {
                    label
                }
            }
        }
        .onAppear { expanded = group.isExpanded ?? true }
        .sheet(isPresented: $renaming) {
            NameSheet(title: L("Renombrar grupo"), placeholder: L("Nombre"), action: L("Guardar"), initial: group.displayName) { model.renameGroup(group.uuid, to: $0) }
        }
    }

    /// Al abrir, la lista ya anima sola; al cerrar hay que pedírselo (con animación en los dos se perdía la de abrir).
    private var toggle: Binding<Bool> {
        Binding(get: { expanded }, set: { open in
            if open || reduceMotion { expanded = open } else { withAnimation(.easeInOut(duration: 0.2)) { expanded = false } }
        })
    }

    private var label: some View {
        SidebarLabel(item: .group(group.uuid), title: group.displayName, symbol: "folder")
            .contextMenu {
                if model.isGroupInRecycleBin(group.uuid) {
                    Button("Restaurar") { model.restore(group.uuid) }
                } else {
                    Button("Nuevo subgrupo…") { model.requestNewGroup(in: group.uuid) }
                    Button("Renombrar…") { renaming = true }
                }
                Divider()
                Button(model.groupDeletesPermanently(group.uuid) ? "Eliminar para siempre…" : "Mover a la papelera", role: .destructive) { model.deleteGroup(group.uuid) }
            }
    }
}

/// Pie de la barra lateral: la base abierta (pulsa para cambiar) y bloquear todas.
private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            DatabaseSwitcher()
            IconButton(symbol: "lock", help: L("Bloquear todas (⇧⌘L)"), size: 30) { model.lockAll() }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .hairline(.top)
    }
}

/// Fila de auditoría: escudo naranja si hay problemas, verde si está todo bien.
private struct AuditLabel: View {
    /// Por qué no se puede decir que una comprobación esté limpia (nil si el resultado es fiable).

    @Environment(AppModel.self) private var model
    let kind: AuditKind
    let title: String

    var body: some View {
        let count = model.count(.audit(kind))
        let serious = kind == .pwned
        let gap = model.auditGap(kind)
        let unknown = count == 0 ? gap?.text : nil
        Label {
            HStack(spacing: 6) {
                Text(title)
                if kind == .pwned && AuditServices.shared.checking > 0 {
                    ProgressView().controlSize(.mini).help("Comprobando filtraciones…")
                }
            }
        } icon: {
            // Sin resultado fiable no se pinta el escudo verde: «no comprobado» no es «todo bien».
            Image(systemName: count > 0 ? "exclamationmark.shield" : (unknown != nil ? "shield" : "checkmark.shield"))
                .foregroundStyle(count > 0 ? (serious ? Theme.red : Theme.amber) : (unknown != nil ? Theme.textTertiary : Theme.green))
                .help(gap?.text ?? "")
        }
        .lineLimit(1)
        .badge(count)
        .accessibilityLabel(title)
        .accessibilityValue([count > 0 ? L("\(count) con problemas") : (unknown == nil ? L("sin problemas") : nil), gap?.text].compactMap { $0 }.joined(separator: ". "))
        .tag(SidebarItem.audit(kind))
    }
}

struct NameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let placeholder: String
    let action: String
    var initial = ""
    let onSave: (String) -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.ui(16, .semibold))
            GField(focused: focused) { TextField(placeholder, text: $name).focused($focused).onSubmit(save) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.buttonStyle(GButtonStyle(kind: .secondary)).keyboardShortcut(.cancelAction)
                Button(action, action: save).buttonStyle(GButtonStyle(kind: .primary)).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
        .onAppear { name = initial; focused = true }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}

// MARK: - Lista de entradas

private struct EntryListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var focus: FocusState<FocusArea?>.Binding

    var body: some View {
        let entries = model.visibleEntries
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.search.isEmpty ? model.sidebarTitle : L("Resultados"))
                    .font(.ui(20, .semibold))
                    .tracking(-0.3)
                    .lineLimit(1)
                Text("\(entries.count)").font(.ui(14)).foregroundStyle(Theme.textTertiary)
                Spacer()
                if model.sidebar == .recycleBin, !entries.isEmpty {
                    Button("Vaciar") { model.confirmEmptyRecycleBin() }.buttonStyle(GButtonStyle(kind: .secondary, compact: true))
                }
                if !model.search.isEmpty { SearchOptionsMenu() }
                SortMenu()
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // Si una comprobación no ha terminado o ha fallado, se dice aquí aunque ya haya problemas.
            if case let .audit(kind) = model.sidebar, model.search.isEmpty, let gap = model.auditGap(kind), !entries.isEmpty {
                HStack(spacing: 8) {
                    if gap.pending {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    }
                    Text(gap.text).font(.ui(12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    Spacer(minLength: 8)
                    if !gap.pending {
                        Button("Reintentar") { model.retryAuditChecks() }.buttonStyle(GButtonStyle(kind: .secondary, compact: true))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill))
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            if entries.isEmpty {
                EmptyState(searching: !model.search.isEmpty)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(entries, id: \.uuid) { entry in
                                EntryRow(entry: entry, listFocused: focus.wrappedValue == .entries).id(entry.uuid)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                    }
                    .onChange(of: model.selectedEntryID) { _, id in
                        if let id { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
                    }
                    // Con ⇧+flechas el detalle se queda en la entrada de partida; se sigue el otro extremo del rango.
                    .onChange(of: model.selection) { _, selection in
                        guard selection.count > 1, let end = model.rangeEnd, selection.contains(end) else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(end) }
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .focused(focus, equals: .entries)
                .onKeyPress(keys: [.downArrow, .upArrow], phases: [.down, .repeat]) { press in
                    let delta = press.key == .downArrow ? 1 : -1
                    // ⇧ amplía o reduce la selección desde la entrada de partida, como en el Finder.
                    if press.modifiers.contains(.shift) { model.extendSelection(delta) } else { model.moveSelection(delta) }
                    return .handled
                }
                .onKeyPress(.return) { if let id = model.selectedEntryID { model.edit(id) }; return .handled }
                .onKeyPress(.delete) { model.deleteSelected(); return .handled }
                .onKeyPress(.deleteForward) { model.deleteSelected(); return .handled }
                .onKeyPress(.escape) {
                    if model.isMultiSelecting { model.selectedEntryID = model.selectedEntryID; return .handled }
                    guard !model.search.isEmpty else { return .ignored }
                    model.search = ""
                    return .handled
                }
            }
        }
        .background(Theme.background)
    }
}

private struct SortMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(SortKey.allCases, id: \.self) { key in
                Button {
                    if model.sortKey == key { model.sortAscending.toggle() } else { model.sortKey = key; model.sortAscending = ![.modified, .created, .passwordChanged].contains(key) }
                } label: {
                    if model.sortKey == key {
                        Label(key.label, systemImage: model.sortAscending ? "arrow.up" : "arrow.down")
                    } else {
                        Text(key.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .semibold))
                Text(model.sortKey.label)
            }
            .font(.ui(12, .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Theme.fill))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ordenar")
    }
}

private struct EntryRow: View {
    @Environment(AppModel.self) private var model
    let entry: KDBX.Entry
    var listFocused = false
    @State private var hovering = false

    var selected: Bool { model.selection.contains(entry.uuid) }
    /// En la fila seleccionada el gris terciario no tiene contraste suficiente sobre el fondo.
    private var metaColor: Color { selected ? Theme.textSecondary : Theme.textTertiary }

    var body: some View {
        HStack(spacing: 14) {
            EntryIcon(entry: entry, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(entry.title.isEmpty ? L("Sin título") : entry.title)
                        .font(.ui(13, .semibold))
                        .lineLimit(1)
                    if entry.kind != .login {
                        Image(systemName: entry.kind.symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    }
                    if entry.isFavorite {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Theme.amber)
                    }
                    if TOTP.from(entry) != nil {
                        Image(systemName: "clock").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    }
                    if let issue = auditIssue {
                        Image(systemName: issue.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(issue.color)
                            .help(issue.help)
                            .accessibilityLabel(issue.help)
                    }
                }
                Text(subtitle)
                    .font(.ui(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Self.host(entry.url))
                    .font(.ui(12))
                    .foregroundStyle(metaColor)
                    .lineLimit(1)
                Text(entry.modified.map(Self.relative) ?? "")
                    .font(.ui(11))
                    .foregroundStyle(metaColor)
            }
            .frame(maxWidth: 140, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.selected : (hovering ? Theme.hover : .clear)))
        // Con el teclado en la lista, la fila seleccionada lleva un borde: así se ve dónde está el foco.
        .overlay {
            if selected && listFocused {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.textTertiary)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.edit(entry.uuid) }
        .simultaneousGesture(TapGesture().onEnded {
            model.click(entry.uuid, modifiers: NSEvent.modifierFlags)
            model.focusRequest = .entries
        })
        .draggable(entry.uuid.uuidString)
        .contextMenu { EntryMenu(entry: entry) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.click(entry.uuid, modifiers: []) }
    }

    /// En la auditoría, qué le pasa a la entrada sin tener que abrirla.
    private var auditIssue: (symbol: String, color: Color, help: String)? {
        guard case .audit = model.sidebar else { return nil }
        let audit = model.audit
        if let times = audit.pwned[entry.uuid] { return ("exclamationmark.shield.fill", Theme.red, L("Filtrada \(times) veces")) }
        if audit.duplicates[entry.uuid] != nil { return ("exclamationmark.shield", Theme.amber, L("Repetida")) }
        if audit.allWeak.contains(entry.uuid) { return ("exclamationmark.shield", Theme.amber, L("Débil")) }
        if audit.similar[entry.uuid] != nil { return ("exclamationmark.shield", Theme.amber, L("Parecida a otra")) }
        if audit.missing2FA.contains(entry.uuid) { return ("exclamationmark.shield", Theme.amber, L("Sin 2FA")) }
        if audit.expired.contains(entry.uuid) { return ("calendar.badge.exclamationmark", Theme.amber, L("Caducada")) }
        return nil
    }

    private var subtitle: String {
        switch entry.kind {
        case .card:
            let digits = entry.string(CardField.number).filter(\.isNumber)
            return digits.count >= 4 ? "•••• " + digits.suffix(4) : L("Tarjeta")
        case .note:
            return entry.notes.split(separator: "\n").first.map(String.init) ?? L("Nota")
        case .login:
            return model.hideUsernames ? "••••••" : (entry.userName.isEmpty ? L("Sin usuario") : model.value(FieldKey.userName, of: entry))
        }
    }

    static func host(_ url: String) -> String {
        guard let parsed = URL.fromUserInput(url), let host = parsed.host() else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = appLocale
        formatter.unitsStyle = .short
        return abs(Date().timeIntervalSince(date)) < 60 ? L("ahora") : formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct EntryMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let entry: KDBX.Entry

    var body: some View {
        if model.isMultiSelecting && model.selection.contains(entry.uuid) {
            multiMenu
        } else {
            singleMenu
        }
    }

    @ViewBuilder
    private var multiMenu: some View {
        let ids = model.selectedIDs
        Text("\(ids.count) entradas seleccionadas")
        Button("Añadir a favoritos") { model.setFavorite(true, for: ids) }
        Button("Quitar de favoritos") { model.setFavorite(false, for: ids) }
        if let root = model.root {
            Menu("Mover a") {
                ForEach(root.flattened(excluding: model.vault?.excludedFromBrowsing ?? []), id: \.group.uuid) { item in
                    Button(String(repeating: "   ", count: item.level) + item.group.displayName) { model.moveSelection(to: item.group.uuid) }
                }
            }
        }
        Button("Exportar a CSV…") { model.export(only: Set(ids), withAttachments: false) }
        Divider()
        if ids.allSatisfy(model.isInRecycleBin) {
            Button("Restaurar") { ids.forEach(model.restore) }
        }
        Button(model.deleteTitle(for: ids), role: .destructive) { model.deleteSelection() }
    }

    @ViewBuilder
    private var singleMenu: some View {
        if entry.kind == .card {
            Button(L("Copiar número")) { model.copy(model.value(CardField.number, of: entry), label: L("Número"), entry: entry.uuid) }
            Button("Copiar CVV") { model.copy(model.value(CardField.cvv, of: entry), label: "CVV", entry: entry.uuid) }
        } else if entry.kind == .login {
            Button("Copiar usuario") { model.copy(model.value(FieldKey.userName, of: entry), label: "Usuario", entry: entry.uuid) }
            Button(L("Copiar contraseña")) { model.copy(model.value(FieldKey.password, of: entry), label: L("Contraseña"), entry: entry.uuid) }
            if let email = entry.email, email != entry.userName {
                Button("Copiar email") { model.copy(email, label: "Email", entry: entry.uuid) }
            }
            if !entry.url.isEmpty {
                Button("Copiar web") { model.copy(model.value(FieldKey.url, of: entry), label: "Web", entry: entry.uuid) }
            }
            if let totp = TOTP.from(entry) {
                Button(L("Copiar código 2FA")) { model.copy(totp.code(), label: L("Código 2FA"), entry: entry.uuid) }
            }
            if URL.fromUserInput(entry.url) != nil {
                Button("Copiar contraseña y abrir web") { model.copyPasswordAndOpenURL(entry) }
            }
        }
        Menu("Copiar más") {
            if entry.kind == .login { Button("Usuario y contraseña") { model.copyUserAndPassword(entry) } }
            Button("Todos los campos") { model.copyAllFields(entry) }
            if !entry.notes.isEmpty { Button(L("Notas")) { model.copy(entry.notes, label: L("Notas"), entry: entry.uuid) } }
            Divider()
            Button("Referencia al usuario") { model.copyReference("U", of: entry) }
            Button("Referencia a la contraseña") { model.copyReference("P", of: entry) }
            Divider()
            Button("Entrada completa (para pegar en otra base)") { model.copyEntry(entry.uuid) }
        }
        Divider()
        Button(entry.isFavorite ? "Quitar de favoritos" : "Añadir a favoritos") { model.toggleFavorite(entry.uuid) }
        Button("Editar") { model.edit(entry.uuid) }
        Button("Duplicar") { model.duplicate(entry.uuid) }
        Button("Abrir en otra ventana") {
            if let url = model.vault?.url { openWindow(id: "entry", value: PopOutTarget(entryID: entry.uuid, vault: url)) }
        }
        if !entry.history.isEmpty {
            Button("Historial…") { model.selectedEntryID = entry.uuid; model.sheet = .history }
        }
        Menu("Icono") {
            Button("Elegir imagen…") { model.pickIcon(for: entry.uuid) }
            if !entry.url.isEmpty { Button("Guardar el logo de la web en la base") { model.useFaviconAsIcon(entry) } }
            if entry.customIconUUID != nil { Button("Quitar icono propio") { model.removeIcon(entry.uuid) } }
        }
        Button(entry.excludedFromAudit ? "Incluir en la auditoría" : "Excluir de la auditoría") { model.toggleAuditExclusion(entry.uuid) }
        if let root = model.root {
            Menu("Mover a") {
                ForEach(root.flattened(excluding: model.vault?.excludedFromBrowsing ?? []), id: \.group.uuid) { item in
                    Button(String(repeating: "   ", count: item.level) + item.group.displayName) { model.move(entry.uuid, to: item.group.uuid) }
                }
            }
        }
        Divider()
        if model.isInRecycleBin(entry.uuid) {
            Button("Restaurar") { model.restore(entry.uuid) }
        }
        Button(model.deleteTitle(for: [entry.uuid]), role: .destructive) {
            model.delete(entry.uuid)
        }
    }
}

private struct EmptyState: View {
    @Environment(AppModel.self) private var model
    let searching: Bool

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: content.symbol)
                .font(.system(size: 18))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.fill))
            Text(content.title)
                .font(.ui(14, .semibold))
            Text(content.detail)
                .font(.ui(13))
                .foregroundStyle(Theme.textSecondary)
            if case let .audit(kind) = model.sidebar, let gap = model.auditGap(kind), !gap.pending {
                Button("Reintentar") { model.retryAuditChecks() }
                    .buttonStyle(GButtonStyle(kind: .secondary, compact: true))
                    .padding(.top, 4)
            }
            if content.offersNew {
                Button("Nueva entrada") { model.newEntry() }
                    .buttonStyle(GButtonStyle(kind: .primary, compact: true))
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Texto según dónde estés: una auditoría limpia o una papelera vacía no invitan a crear entradas.
    private var content: (symbol: String, title: String, detail: String, offersNew: Bool) {
        if searching { return ("magnifyingglass", L("Nada coincide con «\(model.search)»"), L("Busca por título, usuario, web, notas o etiquetas."), false) }
        switch model.sidebar {
        case let .audit(kind):
            if let gap = model.auditGap(kind) { return ("shield", gap.pending ? L("Comprobando…") : L("Sin comprobar"), gap.text, false) }
            return ("checkmark.shield", L("Sin problemas"), L("Ninguna entrada tiene este problema."), false)
        case .recycleBin: return ("trash", L("La papelera está vacía"), L("Lo que borres aparecerá aquí."), false)
        case .favorites: return ("star", L("Aún no hay favoritos"), L("Marca una entrada con la estrella para tenerla a mano."), false)
        default: return ("tray", L("No hay entradas aquí"), L("Crea una con ⌘N."), true)
        }
    }
}

// MARK: - Valores de foco para los menús

struct BrowserFocusKey: FocusedValueKey { typealias Value = FocusArea }

extension FocusedValues {
    var browserFocus: FocusArea? {
        get { self[BrowserFocusKey.self] }
        set { self[BrowserFocusKey.self] = newValue }
    }
}

/// Dónde busca el buscador (aparece mientras hay algo escrito).
private struct SearchOptionsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Section("Buscar en") {
                Toggle("Título", isOn: $model.searchOptions.title)
                Toggle("Usuario", isOn: $model.searchOptions.userName)
                Toggle("Web", isOn: $model.searchOptions.url)
                Toggle("Notas", isOn: $model.searchOptions.notes)
                Toggle("Etiquetas", isOn: $model.searchOptions.tags)
                Toggle("Campos personalizados", isOn: $model.searchOptions.customFields)
            }
            Section {
                Toggle("Incluir versiones anteriores", isOn: $model.searchOptions.includeHistory)
                Toggle("Incluir la papelera", isOn: $model.searchOptions.includeRecycleBin)
                Toggle("Mostrar caducadas", isOn: $model.searchOptions.showExpired)
            }
            Divider()
            Button("Restablecer") { model.searchOptions = SearchOptions() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .semibold))
                Text("Opciones")
            }
            .font(.ui(12, .medium))
            .foregroundStyle(model.searchOptions == SearchOptions() ? Theme.textSecondary : Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Theme.fill))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Dónde buscar")
    }
}

/// Pestañas con las bases abiertas, en la barra de arriba. Solo aparecen si hay más de una abierta.
private struct DatabaseTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let open = model.recents.filter(model.isOpen)
        if open.count > 1 {
            HStack(spacing: 2) {
                ForEach(open, id: \.self) { url in
                    DatabaseTab(url: url, active: url == model.activeURL)
                }
            }
            .padding(3)
            .background(Capsule().fill(Theme.fill))
        }
    }
}

private struct DatabaseTab: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let active: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button { model.switchTo(url) } label: {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.ui(12, .medium))
                    .foregroundStyle(active ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityHint(active ? "" : "Cambiar a esta base")
            // La «x» siempre ocupa su sitio; solo se muestra al pasar el ratón, así la pestaña no cambia de ancho.
            Button { model.lockBackground(url) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 10, height: 10)
            }
            .buttonStyle(.plain)
            .help("Bloquear esta base")
            .opacity(hovering && !active ? 1 : 0)
            .allowsHitTesting(hovering && !active)
            .accessibilityHidden(active)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Capsule().fill(active ? Theme.background : (hovering ? Theme.hover : .clear)))
        .shadow(color: .black.opacity(active ? 0.06 : 0), radius: 2, y: 1)
        .contentShape(Capsule())
        .onTapGesture { model.switchTo(url) }  // Toda la pastilla es pulsable, no solo el texto.
        .onHover { hovering = $0 }
        .help(active ? "Base activa" : "Cambiar a esta base")
    }
}
