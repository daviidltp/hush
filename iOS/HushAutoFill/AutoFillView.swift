import BovedaCore
import KDBXKit
import LocalAuthentication
import Observation
import SwiftUI

@MainActor
@Observable
final class AutoFillModel {
    enum Mode { case password, oneTimeCode }
    enum Result { case password(String, String), code(String), cancel }

    var mode: Mode = .password
    /// Webs o dominios que pide el sistema («github.com», «https://github.com/login»…).
    private(set) var services: [String] = []
    let databases = Preferences.databases
    var selectedID: UUID? = Preferences.lastDatabase
    private(set) var vault: Vault?
    var busy = false
    var error: String?
    @ObservationIgnored var finish: (Result) -> Void = { _ in }

    var selected: SavedDatabase? { databases.first { $0.id == selectedID } ?? databases.first }

    func start(mode: Mode, services: [String]) {
        self.mode = mode
        self.services = services
    }

    var serviceName: String? {
        services.lazy.compactMap { BrowserMatch.host(of: $0) }.first
    }

    func canUseFaceID(_ db: SavedDatabase) -> Bool {
        Preferences.faceIDEnabled && BiometricKeychain.has(db.quickUnlockKey)
    }

    func unlockWithFaceID() async {
        guard let db = selected, canUseFaceID(db), !busy else { return }
        error = nil
        do {
            let unlock = try await BiometricKeychain.load(db.quickUnlockKey, reason: "Rellenar con \(db.name)")
            try await open(db, unlock: unlock)
        } catch BiometricKeychain.Failure.cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func unlock(password: String) async {
        guard let db = selected else { return }
        error = nil
        do {
            var keyData: Data?
            if let bookmark = db.keyFileBookmark {
                let url = try Bookmarks.resolve(bookmark).url
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                keyData = try Data(contentsOf: url)
            }
            let unlock: UnlockData
            if let keyData {
                unlock = password.isEmpty ? try UnlockData(keyFile: keyData) : try UnlockData(masterPassword: password, keyFile: keyData)
            } else {
                unlock = UnlockData(masterPassword: password)
            }
            try await open(db, unlock: unlock)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(_ db: SavedDatabase, unlock: UnlockData) async throws {
        busy = true
        defer { busy = false }
        let url = try Bookmarks.resolve(db.bookmark).url
        let opened = try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try Vault.open(url: url, unlock: unlock)
        }.value
        withAnimation(Theme.spring) { vault = opened }
    }

    // MARK: Entradas

    private var all: [KDBX.Entry] {
        guard let vault else { return [] }
        return vault.root.allEntries(excluding: vault.excludedFromBrowsing)
            .filter { mode == .password ? !$0.string(FieldKey.password).isEmpty : TOTP.from($0) != nil }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Entradas de la web que pide el sistema.
    var suggestions: [KDBX.Entry] {
        guard let vault else { return [] }
        let pages = services.map { $0.contains("://") ? $0 : "https://" + $0 }
        return all.filter { entry in pages.contains { BrowserMatch.matches(page: $0, entry: entry, resolve: { vault.resolve($0) }) } }
    }

    func others(_ query: String) -> [KDBX.Entry] {
        let ids = Set(suggestions.map(\.uuid))
        let q = query.trimmingCharacters(in: .whitespaces)
        return all.filter { !ids.contains($0.uuid) }.filter { entry in
            q.isEmpty || [entry.title, entry.userName, entry.url].contains { $0.localizedStandardContains(q) }
        }
    }

    func choose(_ entry: KDBX.Entry) {
        guard let vault else { return }
        switch mode {
        case .password:
            finish(.password(vault.resolve(entry.userName), vault.resolve(entry.string(FieldKey.password))))
        case .oneTimeCode:
            if let totp = TOTP.from(entry) { finish(.code(totp.code())) }
        }
    }
}

// MARK: - Vistas

struct AutoFillView: View {
    @Environment(AutoFillModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.vault != nil {
                    AutoFillList()
                } else if let db = model.selected {
                    AutoFillUnlock(db: db)
                } else {
                    ContentUnavailableView("Sin bases", systemImage: "key.horizontal",
                                           description: Text("Abre Hush y elige tu archivo de contraseñas primero."))
                }
            }
            .background(HushBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", systemImage: "xmark") { model.finish(.cancel) }
                }
            }
        }
        .tint(Theme.text)
    }
}

struct AutoFillUnlock: View {
    @Environment(AutoFillModel.self) private var model
    let db: SavedDatabase
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            VStack(spacing: 6) {
                AppMark(size: 60).padding(.bottom, 10)
                if model.databases.count > 1 {
                    Picker("Base", selection: $model.selectedID) {
                        ForEach(model.databases) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.menu)
                    .font(.title3.weight(.bold))
                } else {
                    Text(db.name).font(.title2.weight(.bold)).tracking(-0.3)
                }
                if let service = model.serviceName {
                    Text(model.mode == .password ? "Contraseña para \(service)" : "Código para \(service)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if model.canUseFaceID(db) {
                Button { Task { await model.unlockWithFaceID() } } label: {
                    Image(systemName: "faceid")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.text)
                        .frame(width: 66, height: 66)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(.top, 24)
                .accessibilityLabel("Desbloquear con Face ID")
            }
            Spacer(minLength: 16)
            VStack(spacing: 12) {
                SecureField("Contraseña maestra", text: $password)
                    .textContentType(.password)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .padding(.horizontal, 20)
                    .frame(height: 52)
                    .glassEffect(.regular.interactive(), in: .capsule)
                if model.busy { ProgressView().transition(.opacity) }
                if let error = model.error {
                    Text(error).font(.footnote).foregroundStyle(Theme.red).multilineTextAlignment(.center)
                }
                Button("Desbloquear") { submit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.busy || (password.isEmpty && db.keyFileBookmark == nil))
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 12)
        }
        .animation(Theme.spring, value: model.error)
        .task {
            if model.canUseFaceID(db) { await model.unlockWithFaceID() } else { focused = true }
        }
    }

    private func submit() {
        let typed = password
        Task { await model.unlock(password: typed) }
    }
}

struct AutoFillList: View {
    @Environment(AutoFillModel.self) private var model
    @State private var query = ""

    var body: some View {
        let suggestions = model.suggestions
        let others = model.others(query)
        List {
            if !suggestions.isEmpty, query.isEmpty {
                Section(model.serviceName.map { "Para \($0)" } ?? "Sugerencias") {
                    ForEach(suggestions, id: \.uuid) { row($0) }
                }
            }
            Section(query.isEmpty ? "Todas" : "Resultados") {
                ForEach(others, id: \.uuid) { row($0) }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(model.mode == .password ? "Elige una contraseña" : "Elige un código")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar")
    }

    private func row(_ entry: KDBX.Entry) -> some View {
        Button { model.choose(entry) } label: {
            HStack(spacing: 12) {
                EntryAvatar(title: entry.title, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title.isEmpty ? "Sin título" : entry.title).font(.body.weight(.medium)).foregroundStyle(Theme.text)
                    Text(entry.userName.isEmpty ? (BrowserMatch.host(of: entry.url) ?? " ") : entry.userName)
                        .font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: model.mode == .password ? "key.horizontal" : "clock")
                    .font(.subheadline).foregroundStyle(Theme.textTertiary)
            }
        }
        .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)
    }
}
