import BovedaCore
import KDBXKit
import SwiftUI

/// Auditoría: resumen en tarjetas de cristal (que filtran la lista) y las entradas con problemas debajo.
struct AuditScreen: View {
    @Environment(AppModel.self) private var model
    @State private var category: Category = .all

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
            VStack(spacing: 16) {
                if let audit = model.audit {
                    summary(audit)
                    breachesRow
                    list(audit)
                } else {
                    ProgressView("Revisando contraseñas…")
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 120)
        }
        .background(HushBackground())
        .navigationTitle("Auditoría")
        .navigationDestination(for: UUID.self) { EntryDetailView(id: $0) }
    }

    private func summary(_ audit: Audit) -> some View {
        let tiles = Category.allCases.filter { $0 != .all }
        return GlassEffectContainer(spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(tiles) { tile in
                    let count = tile.ids(audit).count
                    let active = category == tile
                    Button {
                        withAnimation(Theme.spring) { category = active ? .all : tile }
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: tile.symbol)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(count > 0 && tile == .pwned ? Theme.red : Theme.text)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(count)")
                                    .font(.title.weight(.bold).monospacedDigit())
                                    .contentTransition(.numericText())
                                Text(tile.title)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(active ? .regular.tint(Theme.text.opacity(0.12)).interactive() : .regular.interactive(),
                                 in: RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
                    .accessibilityLabel("\(tile.title): \(count)")
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder private var breachesRow: some View {
        @Bindable var model = model
        Card {
            Toggle(isOn: $model.checkBreaches) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Buscar en filtraciones")
                    Text(model.pwnedChecking ? "Comprobando…" : "Solo se envían 5 caracteres de la huella de cada contraseña, nunca la contraseña.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.green)
            .padding(16)
        }
    }

    private func list(_ audit: Audit) -> some View {
        let ids = category.ids(audit)
        let entries = (model.vault?.root.allEntries(excluding: model.excluded) ?? [])
            .filter { ids.contains($0.uuid) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return VStack(spacing: 6) {
            SectionLabel(text: category == .all ? "Con problemas" : category.title)
            if entries.isEmpty {
                Card {
                    Label("Todo en orden", systemImage: "checkmark.seal")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.green)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                }
            } else {
                Card {
                    ForEach(Array(entries.enumerated()), id: \.element.uuid) { index, entry in
                        if index > 0 { RowDivider(inset: 68) }
                        NavigationLink(value: entry.uuid) {
                            HStack(alignment: .top, spacing: 12) {
                                EntryAvatar(title: entry.title, icon: model.icon(for: entry))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title.isEmpty ? "Sin título" : entry.title)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(Theme.text)
                                    ForEach(audit.issues(for: entry.uuid).filter { !$0.contains("2FA") }, id: \.self) { issue in
                                        Text(issue)
                                            .font(.footnote)
                                            .foregroundStyle(audit.pwned[entry.uuid] != nil && issue.contains("filtraciones") ? Theme.red : Theme.textSecondary)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowPressStyle())
                    }
                }
            }
        }
        .animation(Theme.spring, value: category)
    }
}
