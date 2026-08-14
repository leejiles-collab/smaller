import UIKit
import SwiftUI
import UniformTypeIdentifiers
import SmallerKit

/// Hosts the sheet and owns the one thing UIKit still has to do: handing the
/// finished file back to whatever app the user shared from.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .compactMap(\.attachments)
            .flatMap { $0 } ?? []

        let flow = ShareFlowView(
            providers: providers,
            onFinish: { [weak self] url in self?.complete(with: url) },
            onCancel: { [weak self] in self?.cancel() },
            onOpenApp: { [weak self] url in self?.openApp(url) }
        )

        let host = UIHostingController(rootView: flow)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }

    /// Returns the compressed file to the host.
    ///
    /// The URL points into the App Group container, not our temporary
    /// directory: Mail reads the attachment after this extension has already
    /// been torn down, and anything in our own container is gone by then.
    private func complete(with url: URL?) {
        guard let url else {
            cancel()
            return
        }
        let provider = NSItemProvider(contentsOf: url)
        let item = NSExtensionItem()
        item.attachments = provider.map { [$0] } ?? []
        extensionContext?.completeRequest(returningItems: [item])
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(
            domain: NSCocoaErrorDomain, code: NSUserCancelledError
        ))
    }

    /// Opens the main app on a file the extension declined to take on.
    ///
    /// `UIApplication.shared` does not exist in an extension, so this walks the
    /// responder chain to find something that will open a URL for us — the
    /// documented way for an app extension to launch its container app.
    private func openApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:]) { [weak self] _ in
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
                return
            }
            responder = current.next
        }
        extensionContext?.completeRequest(returningItems: nil)
    }
}
