import SwiftUI
import UniformTypeIdentifiers

@main
struct HushApp: App {
    @State private var model: AppModel

    init() {
        AppGroup.configure()
        _model = State(initialValue: AppModel())
    }

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
