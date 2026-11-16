import BovedaCore
import KDBXKit
import SwiftUI

/// Auditoría: resumen en tarjetas; cada una abre la lista de entradas de ese apartado.
struct AuditScreen: View {
    @Environment(AppModel.self) private var model

    enum Category: String, CaseIterable, Identifiable {
        case all, pwned, reused, similar, weak, expired
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "Todas"
            case .pwned: return "Filtradas"
            case .reused: return "Repetidas"
            case .similar: return "Parecidas"
            case .weak: return "Débiles"
            case .expired: return "Caducadas"
            }
        }

        var symbol: String {
            switch self {
            case .all: return "exclamationmark.shield"
            case .pwned: return "exclamationmark.triangle"
            case .reused: return "square.on.square"
            case .similar: return "equal.square"
            case .weak: return "lock.open"
            case .expired: return "calendar.badge.exclamationmark"
            }
        }

        func ids(_ audit: Audit) -> Set<UUID> {
            switch self {
            case .all: return audit.all.subtracting(audit.missing2FA).union(audit.pwned.keys)
            case .pwned: return Set(audit.pwned.keys)
            case .reused: return Set(audit.duplicates.keys)
            case .similar: return Set(audit.similar.keys)
            case .weak: return audit.allWeak
            case .expired: return audit.expired
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let audit = model.audit {
                    tile(.pwned, audit: audit, wide: true)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach([Category.reused, .similar, .weak, .expired]) { tile($0, audit: audit, wide: false) }
                    }
                    allRow(audit)
                    breachesRow.padding(.top, 12)
                } else {
                    ProgressView("Revisando contraseñas…")
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .background(HushBackground())
        .navigationTitle("Auditoría")
        .navigationDestination(for: Category.self) { AuditListScreen(category: $0) }
        .navigationDestination(for: UUID.self) { EntryDetailView(id: $0) }
    }

    /// Tarjeta con el número de entradas de una categoría. Tocarla abre la lista.
    private func tile(_ tile: Category, audit: Audit, wide: Bool) -> some View {
        let count = tile.ids(audit).count
        let alert = count > 0 && tile == .pwned
        return NavigationLink(value: tile) {
            HStack(alignment: wide ? .center : .top, spacing: 12) {
                VStack(alignment: .leading, spacing: wide ? 4 : 10) {
                    Image(systemName: tile.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(alert ? Theme.red : Theme.textSecondary)
                    if wide {
                        Text(tile.title).font(.headline).foregroundStyle(Theme.text)
                        Text(checkingText).font(.footnote).foregroundStyle(Theme.textSecondary)
                    } else {
                        Text("\(count)").font(.title2.weight(.bold).monospacedDigit()).foregroundStyle(Theme.text)
                            .contentTransition(.numericText())
                        Text(tile.title).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                if wide {
                    Text("\(count)")
                        .font(.largeTitle.weight(.bold).monospacedDigit())
                        .foregroundStyle(alert ? Theme.red : Theme.text)
                        .contentTransition(.numericText())
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous).fill(Theme.backgroundSubtle))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
        }
        .buttonStyle(TilePressStyle())
        .accessibilityLabel("\(tile.title): \(count)")
    }

    private func allRow(_ audit: Audit) -> some View {
        NavigationLink(value: Category.all) {
            HStack {
                Text("Ver todas con problemas").foregroundStyle(Theme.text)
                Spacer()
                Text("\(Category.all.ids(audit).count)").monospacedDigit().foregroundStyle(Theme.textSecondary)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous).fill(Theme.backgroundSubtle))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
        }
        .buttonStyle(TilePressStyle())
    }

    private var checkingText: String {
        if !model.checkBreaches { return "Sin comprobar" }
        return model.pwnedChecking ? "Comprobando…" : "En filtraciones conocidas"
    }

    @ViewBuilder private var breachesRow: some View {
        @Bindable var model = model
        Card {
            Toggle(isOn: $model.checkBreaches) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Buscar en filtraciones")
                    Text("Nunca se envía la contraseña.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.green)
            .padding(16)
        }
    }
}

/// Entradas de una categoría de la auditoría.
struct AuditListScreen: View {
    @Environment(AppModel.self) private var model
    let category: AuditScreen.Category

    var body: some View {
        let audit = model.audit
        let ids = audit.map { category.ids($0) } ?? []
        let entries = (model.vault?.root.allEntries(excluding: model.excluded) ?? [])
            .filter { ids.contains($0.uuid) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        List {
            ForEach(entries, id: \.uuid) { entry in
                NavigationLink(value: entry.uuid) {
                    HStack(alignment: .top, spacing: 12) {
                        EntryAvatar(title: entry.title, icon: model.icon(for: entry))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title.isEmpty ? "Sin título" : entry.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Theme.text)
                            ForEach(audit?.issues(for: entry.uuid).filter { !$0.contains("2FA") } ?? [], id: \.self) { issue in
                                Text(issue)
                                    .font(.footnote)
                                    .foregroundStyle(audit?.pwned[entry.uuid] != nil && issue.contains("filtraciones") ? Theme.red : Theme.textSecondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.backgroundSubtle)
                .listRowSeparator(.hidden)
            }
            if entries.isEmpty {
                ContentUnavailableView("Todo en orden", systemImage: "checkmark.seal",
                                       description: Text("No hay contraseñas en este apartado."))
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(HushBackground())
        .navigationTitle(category == .all ? "Con problemas" : category.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Al pulsar una tarjeta se hunde un poco.
struct TilePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 1), value: configuration.isPressed)
    }
}
