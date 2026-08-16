import UIKit
import SwiftUI
import UniformTypeIdentifiers
import SmallerKit

/// Hosts the sheet and owns the one thing UIKit still has to do: handing the
/// finished file back to whatever app the user shared from.
///
/// This is the app's most-used entry point and the one place where a failure has
/// no second chance — the user is halfway through sending an email, and a sheet
/// that shows nothing tells them nothing. So the SwiftUI sheet is layered over a
/// plain UIKit fallback that is always there underneath: if the sheet draws, it
/// covers it completely, and if it never draws, the fallback is what the user
/// reads.
final class ShareViewController: UIViewController {

    /// How long the SwiftUI sheet gets to draw its first frame before we stop
    /// believing it will and show the fallback instead.
    private static let firstFrameDeadline: Duration = .seconds(3)

    private let fallback = FallbackView()
    private var hasDrawn = false
    private var watchdog: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // The floor, installed before anything that could fail.
        fallback.onClose = { [weak self] in self?.cancel() }
        pin(fallback, to: view)

        // Read before marking, or this run overwrites the last one's evidence.
        let unfinished = ShareLiveness.takeUnfinished()
        ShareLiveness.mark(.starting)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .compactMap(\.attachments)
            .flatMap { $0 } ?? []

        let flow = ShareFlowView(
            providers: providers,
            lastRunReport: unfinished?.report,
            onDraw: { [weak self] in self?.noteDrawn() },
            onShare: { [weak self] url in self?.share(url) },
            onCancel: { [weak self] in self?.cancel() },
            onOpenApp: { [weak self] url in self?.openApp(url) }
        )

        let host = UIHostingController(rootView: flow)
        // Opaque, so the fallback beneath it is hidden rather than showing
        // through the sheet's empty space.
        host.view.backgroundColor = .systemBackground
        addChild(host)
        pin(host.view, to: view)
        host.didMove(toParent: self)

        startWatchdog()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // However we are leaving, we are leaving under our own power.
        ShareLiveness.clear()
        watchdog?.cancel()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // The model backs off on its own — see ShareModel — but say it out loud
        // here too so the breadcrumb records how close this run came.
        NotificationCenter.default.post(name: ShareViewController.memoryPressure, object: nil)
    }

    /// Posted when the extension is running out of room, so the model can stop
    /// and render a way forward instead of waiting to be killed.
    static let memoryPressure = Notification.Name("com.smaller.share.memoryPressure")

    // MARK: - Making sure something is on screen

    private func noteDrawn() {
        hasDrawn = true
        watchdog?.cancel()
        watchdog = nil
    }

    /// Covers the case the fallback underneath cannot: the host attaches, paints
    /// its opaque background over us, and then draws nothing.
    private func startWatchdog() {
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.firstFrameDeadline)
            guard !Task.isCancelled, let self, !self.hasDrawn else { return }
            self.fallback.show(
                message: "Smaller couldn't open here.",
                detail: "Open the file in the Smaller app instead — it can do everything this sheet can."
            )
            self.view.bringSubviewToFront(self.fallback)
        }
    }

    private func pin(_ child: UIView, to parent: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    // MARK: - Leaving

    /// Opens the system share sheet on the finished file.
    ///
    /// Presented from UIKit rather than through SwiftUI's `ShareLink`, because
    /// this is an extension: presentation has to come from the view controller
    /// the host actually installed, and a button that silently fails to present
    /// is the exact failure this app has already paid for once.
    ///
    /// The URL points into the App Group container, not our temporary
    /// directory. Whatever the user shares to reads the file after this
    /// extension has been torn down, and anything in our own container is gone
    /// by then.
    private func share(_ url: URL) {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad presents this as a popover and traps without an anchor.
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1
        )
        sheet.completionWithItemsHandler = { [weak self] _, completed, _, _ in
            // Only close on a completed share. A cancelled one should leave the
            // result on screen, since the other button is still worth having.
            guard completed else { return }
            ShareLiveness.clear()
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        present(sheet, animated: true)
    }

    private func cancel() {
        ShareLiveness.clear()
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
        ShareLiveness.clear()
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
        // Nothing on the chain would open it. Say so rather than closing on a
        // silent no-op the user reads as the app being broken.
        fallback.show(
            message: "Smaller couldn't open the app from here.",
            detail: "The file is waiting — open Smaller from the Home Screen and it will be there."
        )
        view.bringSubviewToFront(fallback)
    }
}

/// The plain UIKit sheet under everything, shown when SwiftUI is not what the
/// user is looking at. Deliberately built from nothing but UIKit primitives:
/// it is what has to work when the interesting parts did not.
private final class FallbackView: UIView {

    var onClose: (() -> Void)?

    private let title = UILabel()
    private let detail = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground

        title.text = "Smaller couldn't start."
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true

        detail.text = "Close this and open the file in the Smaller app instead."
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel

        for label in [title, detail] {
            label.numberOfLines = 0
            label.textAlignment = .center
        }

        var configuration = UIButton.Configuration.borderedProminent()
        configuration.title = "Close"
        let close = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.onClose?()
        })

        let stack = UIStackView(arrangedSubviews: [title, detail, close])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(20, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(message: String, detail: String) {
        title.text = message
        self.detail.text = detail
    }
}
