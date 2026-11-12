import AppKit
import BovedaCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Kit de emergencia: una hoja para imprimir con lo necesario para recuperar la base si se pierde el Mac.
/// Nunca lleva la contraseña: hay un hueco para escribirla a mano.
enum EmergencyKit {
    /// Tamaño A4 en puntos.
    static let pageSize = CGSize(width: 595, height: 842)

    @MainActor
    static func pdf(name: String, url: URL) -> Data {
        let page = EmergencyKitPage(name: name, url: url, date: Date())
            .frame(width: pageSize.width, height: pageSize.height)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: page)
        let data = NSMutableData()
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
        }
        return data as Data
    }

    @MainActor
    static func save(name: String, url: URL) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = L("Kit de emergencia de \(name).pdf")
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let target = panel.url else { return nil }
        do {
            try pdf(name: name, url: url).write(to: target, options: .atomic)
            return target
        } catch {
            return nil
        }
    }

    @MainActor
    static func print(name: String, url: URL) {
        guard let document = PDFDocument(data: pdf(name: name, url: url)) else { return }
        let info = NSPrintInfo.shared
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        document.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: false)?
            .runModal(for: NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
    }
}

/// La hoja impresa. Colores fijos (siempre en papel blanco) y tipografía de la app.
private struct EmergencyKitPage: View {
    let name: String
    let url: URL
    let date: Date

    private let ink = Color(white: 0.06)
    private let muted = Color(white: 0.38)
    private let line = Color(white: 0.82)

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 12) {
                AppMark(size: 34).environment(\.colorScheme, .light)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kit de emergencia").font(.ui(22, .semibold)).tracking(-0.4)
                    Text(L("Hush · creado el \(date.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(appLocale)))"))
                        .font(.ui(11)).foregroundStyle(muted)
                }
            }

            Text("Imprime esta hoja, escribe tu contraseña maestra a mano y guárdala en un lugar seguro (por ejemplo, con tus documentos importantes). Si pierdes el Mac o olvidas la contraseña, aquí está todo lo necesario para recuperar tus contraseñas.")
                .font(.ui(12)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)

            box {
                field(L("Base de datos"), name)
                field(L("Archivo"), url.lastPathComponent)
                field(L("Ubicación"), Self.readablePath(url.deletingLastPathComponent()))
            }

            box {
                Text("Contraseña maestra").font(.ui(10, .semibold)).foregroundStyle(muted).textCase(.uppercase)
                VStack(spacing: 30) {
                    Rectangle().fill(line).frame(height: 1)
                    Rectangle().fill(line).frame(height: 1)
                }
                .padding(.top, 34)
                Text("Escríbela a mano. Nunca la guardes en el ordenador ni en una foto.")
                    .font(.ui(10)).foregroundStyle(muted)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Cómo recuperar tus contraseñas").font(.ui(13, .semibold)).foregroundStyle(ink)
                step("1", L("Busca el archivo de arriba. Si se perdió, Hush guarda copias en ~/Library/Application Support/Boveda/Copias y puedes tener otra en tu nube o en un disco."))
                step("2", L("Ábrelo con Hush (github.com/daviidltp/hush) o con cualquier app compatible con archivos KeePass (.kdbx), en Mac, Windows, Linux, iPhone o Android."))
                step("3", L("Escribe la contraseña maestra de esta hoja. Si usas un archivo de clave, necesitarás también una copia de ese archivo."))
            }

            Spacer(minLength: 0)

            Text("Hush no tiene servidores ni cuentas: nadie, ni siquiera quien hace la app, puede recuperar tu contraseña maestra por ti.")
                .font(.ui(10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(ink)
    }

    /// Ruta legible: «iCloud Drive/…» en vez de la carpeta interna de iCloud, y «~» por la carpeta personal.
    static func readablePath(_ folder: URL) -> String {
        let path = folder.path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let iCloud = home + "Library/Mobile Documents/com~apple~CloudDocs/"
        if path.hasPrefix(iCloud) { return "iCloud Drive/" + path.dropFirst(iCloud.count) }
        if path.hasPrefix(home) { return "~/" + path.dropFirst(home.count) }
        return path
    }

    private func box<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(line))
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.ui(10, .semibold)).foregroundStyle(muted).textCase(.uppercase)
            Text(value).font(.mono(11)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.ui(11, .semibold)).foregroundStyle(.white)
                .frame(width: 20, height: 20).background(Circle().fill(ink))
            Text(text).font(.ui(11.5)).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Se ofrece al crear una base y desde el menú «Base de datos».
struct EmergencyKitSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var saved: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lifepreserver")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Guarda tu kit de emergencia").font(.ui(18, .semibold))
                    Text("Si olvidas la contraseña maestra, nadie puede recuperarla. Imprime esta hoja, escribe la contraseña a mano y guárdala en un lugar seguro.")
                        .font(.ui(12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let vault = model.vault {
                KitPreview(name: vault.name, url: vault.url)
            }

            if let saved {
                Label(L("Guardado en \(saved.lastPathComponent)"), systemImage: "checkmark.circle.fill")
                    .font(.ui(12)).foregroundStyle(Theme.green)
            }

            HStack {
                Button(saved == nil ? "Ahora no" : "Listo") { dismiss() }
                    .buttonStyle(GButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Guardar PDF…") {
                    guard let vault = model.vault else { return }
                    saved = EmergencyKit.save(name: vault.name, url: vault.url) ?? saved
                }
                .buttonStyle(GButtonStyle(kind: .secondary))
                Button("Imprimir…") {
                    guard let vault = model.vault else { return }
                    EmergencyKit.print(name: vault.name, url: vault.url)
                }
                .buttonStyle(GButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Theme.background)
    }
}

/// Miniatura de la hoja para que se vea qué se va a imprimir.
private struct KitPreview: View {
    let name: String
    let url: URL

    var body: some View {
        EmergencyKitPage(name: name, url: url, date: Date())
            .frame(width: EmergencyKit.pageSize.width, height: EmergencyKit.pageSize.height)
            .environment(\.colorScheme, .light)
            .scaleEffect(0.3, anchor: .topLeading)
            .frame(width: EmergencyKit.pageSize.width * 0.3, height: EmergencyKit.pageSize.height * 0.3, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
