import SwiftUI
import UniformTypeIdentifiers

@main
struct HushApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

extension UTType {
    static let kdbx = UTType(importedAs: "com.david.hush.kdbx")
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        ZStack {
            if model.vault != nil {
                MainView()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else if let db = model.selected {
                UnlockView(db: db)
                    .id(db.id)
                    .transition(.opacity)
            } else {
                WelcomeView()
                    .transition(.opacity)
            }
            // En el selector de apps no se ve nada de la base.
            if scenePhase != .active, model.vault != nil {
                PrivacyCover().transition(.opacity)
            }
        }
        .animation(Theme.spring, value: model.vault == nil)
        .animation(.easeOut(duration: 0.15), value: scenePhase)
        .tint(Theme.text)
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        .alert(item: $model.alert) { alert in
            if alert.reload {
                Alert(title: Text(alert.title), message: Text(alert.message),
                      primaryButton: .default(Text("Recargar")) { Task { await model.reload() } },
                      secondaryButton: .cancel(Text("Ahora no")))
            } else {
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
            }
        }
    }
}

/// Tapa la pantalla cuando la app no está delante (selector de apps, centro de control…).
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            HushBackground()
            AppMark(size: 72)
        }
    }
}

/// Marca de la app: llave sobre un cuadrado redondeado, como el icono.
struct AppMark: View {
    var size: CGFloat = 76

    var body: some View {
        Image(systemName: "key.horizontal.fill")
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Theme.onPrimary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Theme.primary))
            .accessibilityHidden(true)
    }
}
