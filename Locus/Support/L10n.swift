import Foundation
import MapKit

/// In-app language override.
///
/// `Bundle.main.localizedString(forKey:value:table:)` picks a language from
/// `AppleLanguages` once, when the bundle first resolves that language. Flipping
/// `UserDefaults` later does not change an already-loaded bundle, so switching
/// language at runtime needs a bundle that points at the chosen `.lproj`.
///
/// Pattern: a `Bundle` subclass whose `localizedString` forwards to a swizzled
/// `Bundle.main` instance carrying the class object for the selected language.
enum LocusLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// Shown in the picker. Deliberately bilingual: the row has to be readable
    /// in whichever language is currently applied.
    var displayName: String {
        switch self {
        case .system:
            // Matches the system's language, which is what "system" means here.
            // The two branches are the same word in each language, so this row
            // stays readable whichever language is currently applied.
            return LocusLanguage.isChineseSystem ? "跟随系统" : "System"
        case .simplifiedChinese:
            return "简体中文"
        case .english:
            return "English"
        }
    }

    private static var isChineseSystem: Bool {
        let preferred = Locale.preferredLanguages.first ?? ""
        return preferred.hasPrefix("zh")
    }

    static let storageKey = "locus.language"

    /// The override currently in effect, or `.system`.
    static var current: LocusLanguage {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return LocusLanguage(rawValue: raw) ?? .system
    }

    /// Language code the app is actually rendering in.
    static var activeCode: String {
        let chosen = current
        switch chosen {
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh") ? "zh-Hans" : "en"
        case .simplifiedChinese:
            return "zh-Hans"
        case .english:
            return "en"
        }
    }

    /// Applies the override and swaps the localization bundle.
    static func apply(_ language: LocusLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: storageKey)
        Bundle.setLanguageOverride(language == .system ? nil : activeCode)
    }

    /// Installs the override at launch, before any view text is resolved.
    static func applyStoredLanguage() {
        let chosen = current
        Bundle.setLanguageOverride(chosen == .system ? nil : activeCode)
    }
}

extension Bundle {
    private static var languageBundleKey: UInt8 = 0

    /// Language bundle to use for lookups, or nil when following the system.
    static func setLanguageOverride(_ code: String?) {
        guard let code,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            associatedLanguageBundle = nil
            return
        }
        associatedLanguageBundle = bundle
    }

    fileprivate static var associatedLanguageBundle: Bundle? {
        get { objc_getAssociatedObject(Bundle.main, &languageBundleKey) as? Bundle }
        set { objc_setAssociatedObject(Bundle.main, &languageBundleKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/// Resolves a localized string using the active language override.
///
/// All UI text goes through here. The source literal is the Simplified Chinese
/// text, which doubles as the lookup key in `Localizable.strings`, so the same
/// call works in every language and there is no key-naming to maintain.
///
/// Positional arguments use `%@` in the strings file and are passed through
/// `String(format:)`.
func L(_ template: String, _ arguments: String...) -> String {
    let bundle = Bundle.associatedLanguageBundle ?? Bundle.main
    let translated = bundle.localizedString(forKey: template, value: template, table: nil)
    guard !arguments.isEmpty else { return translated }
    // `String(format:)` with `%@` expects objects, so the variadic strings are
    // wrapped as NSString.
    let objects = arguments.map { $0 as NSString }
    return String(format: translated, arguments: objects)
}

/// Publishes language changes so the UI can rebuild itself.
///
/// SwiftUI has no notion of a language change: strings are read once per body
/// evaluation, so switching language needs the view tree rebuilt. `revision`
/// is used as a `.id()` on the root, which does exactly that.
final class LocusLanguageStore: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var language: LocusLanguage = LocusLanguage.current

    /// The map's live camera, kept up to date by the map itself.
    ///
    /// Switching language rebuilds the whole tree, so the map is destroyed and
    /// comes back at its initial region. Restoring from `UserDefaults` is not
    /// enough: that value is only written when a gesture settles, so straight
    /// after launch it still holds an old default. Recording every visible-region
    /// change means the camera is current whether the map was panned, zoomed, or
    /// positioned programmatically.
    ///
    /// Deliberately not `@Published`: it changes on every frame of a pan and must
    /// not trigger view updates.
    var liveMapRegion: MKCoordinateRegion?

    /// True when the map should re-apply `liveMapRegion` because a rebuild just
    /// discarded its state.
    var needsCameraRestore = false

    func set(_ language: LocusLanguage) {
        guard language != self.language else { return }
        LocusLanguage.apply(language)
        self.language = language
        needsCameraRestore = liveMapRegion != nil
        revision += 1
    }
}
