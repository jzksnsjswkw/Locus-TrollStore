import UIKit
import UniformTypeIdentifiers

/// Small UIKit shims used where SwiftUI's own presentation is unreliable.
///
/// Presenting an alert from a SwiftUI view fails when that view owns several
/// presentation modifiers (the settings sheet has a cover, two sheets and three
/// alerts). These helpers present from the root controller instead, waiting for
/// any dismissal in flight to finish.
///
/// Document picking lives in `pickDocument(_:onPick:onCancel:)` below.
enum LocusDocumentExchange {
    private static var pendingPresentation: DispatchWorkItem?

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.sorted { rank($0.activationState) < rank($1.activationState) }
        for scene in ordered {
            if let window = scene.windows.first(where: { $0.isKeyWindow }) { return window }
        }
        for scene in ordered {
            if let window = scene.windows.first { return window }
        }
        return UIApplication.shared.windows.first
    }

    private static func rank(_ state: UIScene.ActivationState) -> Int {
        switch state {
        case .foregroundActive: return 0
        case .foregroundInactive: return 1
        case .background: return 2
        case .unattached: return 3
        @unknown default: return 4
        }
    }

    /// Topmost controller that can actually present.
    ///
    /// `keyWindow().rootViewController` is not it when a SwiftUI `.sheet` is up:
    /// the root already has a presented controller and refuses a second one.
    /// UIKit alerts have to go on the visible sheet instead, which is what makes
    /// them appear over the page rather than behind or not at all.
    private static func presenter() -> UIViewController? {
        guard var top = keyWindow()?.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        guard !top.isBeingDismissed, !top.isBeingPresented else { return nil }
        return top
    }

    /// Presents on the topmost controller, waiting only if something is
    /// mid-transition (never merely because a sheet is open).
    fileprivate static func present(_ controller: UIViewController, attempt: Int = 0) {
        if let top = presenter() {
            pendingPresentation?.cancel()
            pendingPresentation = nil
            top.present(controller, animated: true)
            return
        }
        guard attempt < 20 else { return }
        let work = DispatchWorkItem { present(controller, attempt: attempt + 1) }
        pendingPresentation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Opens the system document picker from the root controller.
    ///
    /// Callers dismiss their own sheet first; `present` retries until the root
    /// controller has nothing on it, so the dismissal animation needs no fixed
    /// delay.
    static func pickDocument(
        contentTypes: [UTType],
        onPick: @escaping (URL) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        let coordinator = DocumentPickerCoordinator(onPick: onPick, onCancel: onCancel)
        documentPickerCoordinator = coordinator

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        present(picker)
    }

    /// Retained so the picker delegate outlives the presentation.
    private static var documentPickerCoordinator: DocumentPickerCoordinator?

    private final class DocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        private let onCancel: (() -> Void)?

        init(onPick: @escaping (URL) -> Void, onCancel: (() -> Void)?) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            LocusDocumentExchange.documentPickerCoordinator = nil
            guard let url = urls.first else {
                onCancel?()
                return
            }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            LocusDocumentExchange.documentPickerCoordinator = nil
            onCancel?()
        }
    }

    /// Two-button confirmation.
    static func confirm(
        title: String,
        message: String,
        confirmTitle: String,
        onConfirm: @escaping () -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        // `.destructive` only recolours the button here; unlike SwiftUI's role,
        // it does not pre-empt any list animation.
        alert.addAction(UIAlertAction(title: confirmTitle, style: .destructive) { _ in onConfirm() })
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel) { _ in onCancel?() })
        present(alert)
    }

    /// Three-way confirmation: confirm / decline the optional part / cancel.
    ///
    /// Used where a backup restore has a meaningful subset choice (routes), so
    /// the user does not have to import everything to get the placements.
    static func confirmWithOption(
        title: String,
        message: String,
        confirmTitle: String,
        optionTitle: String,
        onConfirm: @escaping () -> Void,
        onOption: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: confirmTitle, style: .default) { _ in onConfirm() })
        alert.addAction(UIAlertAction(title: optionTitle, style: .default) { _ in onOption() })
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        present(alert)
    }

    /// Single-button notice.
    static func notify(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("确定"), style: .default))
        present(alert)
    }

    /// Text prompt with 取消 / 保存.
    ///
    /// `MapHomeView` already carries three sheets and two alert modifiers; SwiftUI
    /// only drives one presentation per view node, so a fourth alert silently
    /// never appears. Presenting from the root controller sidesteps that.
    static func promptForText(
        title: String,
        message: String,
        placeholder: String,
        initialText: String,
        saveTitle: String = L("保存"),
        onSave: @escaping (String) -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let guardObject = TextFieldGuard()

        alert.addTextField { field in
            field.placeholder = placeholder
            field.text = initialText
            field.addTarget(guardObject, action: #selector(TextFieldGuard.textChanged(_:)), for: .editingChanged)
        }

        let save = UIAlertAction(title: saveTitle, style: .default) { [weak alert] _ in
            onSave(alert?.textFields?.first?.text ?? "")
        }
        save.isEnabled = !initialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        alert.addAction(save)
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))

        guardObject.alert = alert
        guardObject.retained = guardObject
        present(alert)
    }

    /// Keeps the save action disabled while the field is empty.
    private final class TextFieldGuard: NSObject {
        weak var alert: UIAlertController?
        var retained: Any?

        @objc func textChanged(_ sender: UITextField) {
            guard let save = alert?.actions.first else { return }
            save.isEnabled = !(sender.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }

    /// Shares a file through the system share sheet.
    static func share(
        fileAt url: URL,
        onFailure: @escaping (Error) -> Void,
        onFinished: (() -> Void)? = nil
    ) {
        guard let presenter = presenter() else {
            onFailure(LocusDocumentExchangeError.noPresenter)
            return
        }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.completionWithItemsHandler = { _, _, _, _ in onFinished?() }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.permittedArrowDirections = []
        }
        present(activity)
    }
}

enum LocusDocumentExchangeError: LocalizedError {
    case noPresenter

    var errorDescription: String? {
        switch self {
        case .noPresenter:
            return L("当前无法显示分享面板。")
        }
    }
}

/// Reads a file picked or handed to the app.
///
/// `asCopy: true` normally puts the file somewhere this process can read, so a
/// plain read works; the `open(2)` fallback covers paths that Foundation's File
/// Provider checks still refuse while the kernel sandbox allows them.
enum LocusFileReader {
    static func data(from url: URL) throws -> Data {
        if let data = try? Data(contentsOf: url) {
            return data
        }
        return try posixData(from: url)
    }

    private static func posixData(from url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
            )
        }
        defer { close(fd) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
                )
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        guard !data.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return data
    }
}
