import SwiftUI
import UIKit

@main
struct LocusApp: App {
    @UIApplicationDelegateAdaptor(LocusAppDelegate.self) private var appDelegate
    @StateObject private var session = SpoofSession()
    @StateObject private var languageStore = LocusLanguageStore()
    @AppStorage(SetupGate.defaultsKey) private var setupComplete = false

    init() {
        // Resolve the saved language before any view text is built.
        LocusLanguage.applyStoredLanguage()
        ElevationService.loadPersistedCache()
        LegacyCompatibility.applyListAppearance()
    }

    /// Map when setup is finished.
    private var showMap: Bool {
        setupComplete
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if showMap {
                    RootView()
                } else {
                    SetupFlowView {
                        SetupGate.markComplete()
                        setupComplete = true
                    }
                }
            }
            // Rebuilding the tree is what re-evaluates every `L(…)` call after a
            // language change; there is no other way to retranslate live views.
            .id(languageStore.revision)
            .environmentObject(session)
            .environmentObject(languageStore)
            .preferredColorScheme(session.appearanceMode.colorScheme)
            .onOpenURL { url in
                LocusIncomingURL.handle(url, session: session)
            }
            .onAppear {
                LocusAppDelegate.forwardPendingURLIfNeeded()
            }
        }
    }
}

/// Document opens ("Open in Locus" from Files) are delivered to the app
/// delegate, not to SwiftUI's `onOpenURL`, which only reliably reports custom
/// URL schemes. Both paths funnel into `LocusIncomingURL`.
final class LocusAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        Self.deliver(url)
        return true
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if let url = launchOptions?[.url] as? URL {
            Self.pendingURL = url
        }
        return true
    }

    @MainActor
    private static func deliver(_ url: URL) {
        pendingURL = url
        forwardPendingURLIfNeeded()
    }

    @MainActor
    static func forwardPendingURLIfNeeded() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        LocusIncomingURL.handle(url, session: nil)
    }

    /// URLs that arrived before SwiftUI had a chance to install its handlers.
    private static var pendingURL: URL?
}

enum LocusIncomingURL {
    /// Drained by MapHomeView on appear, so a GPX opened during launch — before
    /// the map has subscribed to notifications — is not lost.
    private static var pendingGPX: Data?

    @MainActor
    static func handle(_ url: URL, session: SpoofSession?) {
        if url.scheme == "locus", url.host == "stop" {
            session?.stopJoystick()
            session?.discardRoute()
            session?.stop()
            return
        }

        guard url.pathExtension.lowercased() == "gpx" else { return }

        // Read now: a security-scoped URL handed over by Files stops working once
        // this call returns, and the map only consumes the file later.
        let data: Data
        do {
            data = try LocusFileReader.data(from: url)
        } catch {
            session?.lastError = error.localizedDescription
            return
        }

        pendingGPX = data
        NotificationCenter.default.post(name: .locusImportGPX, object: data)
    }

    static func takePendingGPX() -> Data? {
        defer { pendingGPX = nil }
        return pendingGPX
    }
}

extension Notification.Name {
    static let locusImportGPX = Notification.Name("locusImportGPX")
    static let locusDeleteRoute = Notification.Name("locusDeleteRoute")
    static let locusRunRoute = Notification.Name("locusRunRoute")
    static let locusBuildRouteToTarget = Notification.Name("locusBuildRouteToTarget")
    static let locusCancelDrawingRoute = Notification.Name("locusCancelDrawingRoute")
    static let locusUndoDrawingPoint = Notification.Name("locusUndoDrawingPoint")
    static let locusSaveDrawingRoute = Notification.Name("locusSaveDrawingRoute")
    static let locusEditDrawingRoute = Notification.Name("locusEditDrawingRoute")
    static let locusDismissStatusDetails = Notification.Name("locusDismissStatusDetails")
    static let locusFirstRealFix = Notification.Name("locusFirstRealFix")
}
