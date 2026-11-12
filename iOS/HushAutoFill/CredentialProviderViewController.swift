import AuthenticationServices
import BovedaCore
import SwiftUI

/// Autorrelleno de iOS: aparece al tocar la llave del teclado en un campo de contraseña o de código.
/// Pide Face ID (o la contraseña maestra), sugiere las entradas de esa web y devuelve la elegida.
/// No guarda nada: cada vez abre la base, da la contraseña y la olvida.
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let model = AutoFillModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        AppGroup.configure()
        model.finish = { [weak self] result in self?.finish(result) }
        let host = UIHostingController(rootView: AutoFillView().environment(model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        model.start(mode: .password, services: serviceIdentifiers.map(\.identifier))
    }

    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        model.start(mode: .oneTimeCode, services: serviceIdentifiers.map(\.identifier))
    }

    /// Sin desbloquear no hay nada que dar: siempre hace falta Face ID o la contraseña.
    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userInteractionRequired.rawValue))
    }

    private func finish(_ result: AutoFillModel.Result) {
        switch result {
        case let .password(user, password):
            extensionContext.completeRequest(withSelectedCredential: ASPasswordCredential(user: user, password: password))
        case let .code(code):
            extensionContext.completeOneTimeCodeRequest(using: ASOneTimeCodeCredential(code: code))
        case .cancel:
            extensionContext.cancelRequest(withError: NSError(domain: ASExtensionErrorDomain, code: ASExtensionError.userCanceled.rawValue))
        }
    }
}
