import AppKit
import BovedaCore
import SwiftUI
import UniformTypeIdentifiers

/// Archivo exportado por otra app, leído y listo para revisar antes de importarlo.
struct PendingImport {
    let file: URL
    let result: ImportResult
    /// Firmas de lo que ya está en la base (para avisar de duplicados).
    let known: Set<String>

    var duplicates: [ImportedItem] { result.items.filter { known.contains($0.signature) } }
    func items(skippingDuplicates skip: Bool) -> [ImportedItem] {
        skip ? result.items.filter { !known.contains($0.signature) } : result.items
    }
}

extension AppModel {
    /// Elige un CSV o JSON exportado de otra app y enseña lo que se va a importar.
    func importPasswords() {
        guard let vault else { return }
        let url: URL
        #if DEBUG
        // Solo en la versión de pruebas: abre directamente el archivo indicado (para probar sin el selector).
        if let test = ProcessInfo.processInfo.environment["BOVEDA_TEST_IMPORT"] {
            url = URL(fileURLWithPath: test)
        } else {
            guard let picked = pickImportFile() else { return }
            url = picked
        }
        #else
        guard let picked = pickImportFile() else { return }
        url = picked
        #endif
        do {
            let result = try Importer.read(try Data(contentsOf: url))
            pendingImport = PendingImport(file: url, result: result, known: vault.importSignatures)
            sheet = .importPasswords
        } catch {
            alert = AlertMessage(title: L("No se ha podido importar"), message: error.localizedDescription)
        }
    }

    private func pickImportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.message = L("Elige el archivo exportado de otra app (CSV o JSON sin cifrar)")
        panel.allowedContentTypes = [.commaSeparatedText, .json, .plainText]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Mete lo revisado en un grupo nuevo y lo enseña. Devuelve cuántas entradas se han añadido.
    @discardableResult
    func confirmImport(skippingDuplicates skip: Bool) -> Int {
        guard let pending = pendingImport else { return 0 }
        let items = pending.items(skippingDuplicates: skip)
        guard !items.isEmpty else { return 0 }
        let name = L("Importado el \(Date().formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(appLocale)))")
        var group: UUID?
        mutate { group = $0.importItems(items, intoGroupNamed: name) }
        if let group { sidebar = .group(group) }
        return items.count
    }
}

struct ImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var skipDuplicates = true
    @State private var imported: Int?
    @State private var trashed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let pending = model.pendingImport {
                if let imported {
                    done(imported, pending)
                } else {
                    preview(pending)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.background)
        .onDisappear { model.pendingImport = nil }
    }

    private func preview(_ pending: PendingImport) -> some View {
        let items = pending.items(skippingDuplicates: skipDuplicates)
        let logins = items.filter { $0.kind == .login }.count
        let cards = items.filter { $0.kind == .card }.count
        let notes = items.filter { $0.kind == .note }.count
        let withTOTP = items.filter { !$0.otp.isEmpty }.count
        let duplicates = pending.duplicates.count
        return VStack(alignment: .leading, spacing: 18) {
            header(symbol: "square.and.arrow.down", title: L("Importar contraseñas"), detail: pending.file.lastPathComponent)

            VStack(spacing: 0) {
                row(L("Inicios de sesión"), logins)
                if cards > 0 { Divider().overlay(Theme.border); row(L("Tarjetas"), cards) }
                if notes > 0 { Divider().overlay(Theme.border); row(L("Notas seguras"), notes) }
                if withTOTP > 0 { Divider().overlay(Theme.border); row(L("Con código 2FA"), withTOTP) }
            }
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.fill))

            if duplicates > 0 {
                Toggle(L("Saltar las \(duplicates) que ya están en esta base"), isOn: $skipDuplicates)
                    .toggleStyle(.checkbox)
                    .font(.ui(12))
            }
            if pending.result.skipped > 0 {
                Text(L("\(pending.result.skipped) filas vacías no se importan."))
                    .font(.ui(11)).foregroundStyle(Theme.textTertiary)
            }
            Text("Irán a un grupo nuevo; las carpetas de la otra app se mantienen como subgrupos. Nada se sube a internet.")
                .font(.ui(12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(GButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button(L("Importar \(items.count)")) { imported = model.confirmImport(skippingDuplicates: skipDuplicates) }
                    .buttonStyle(GButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty)
            }
        }
    }

    private func done(_ count: Int, _ pending: PendingImport) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(symbol: "checkmark", title: L("\(count) entradas importadas"), detail: nil)
            VStack(alignment: .leading, spacing: 8) {
                Label("Borra el archivo exportado", systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(13, .semibold)).foregroundStyle(Theme.amber)
                Text(L("«\(pending.file.lastPathComponent)» tiene tus contraseñas sin cifrar. Cualquiera que lo encuentre puede leerlas."))
                    .font(.ui(12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.fill))

            HStack {
                if trashed {
                    Label("En la papelera del Mac", systemImage: "checkmark.circle.fill")
                        .font(.ui(12)).foregroundStyle(Theme.green)
                }
                Spacer()
                if !trashed {
                    Button("Mover a la papelera") {
                        trashed = (try? FileManager.default.trashItem(at: pending.file, resultingItemURL: nil)) != nil
                    }
                    .buttonStyle(GButtonStyle(kind: .secondary))
                }
                Button("Listo") { dismiss() }
                    .buttonStyle(GButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func header(symbol: String, title: String, detail: String?) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(18, .semibold))
                if let detail { Text(detail).font(.ui(12)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle) }
            }
        }
    }

    private func row(_ label: String, _ count: Int) -> some View {
        HStack {
            Text(label).font(.ui(13))
            Spacer()
            Text("\(count)").font(.mono(13)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
