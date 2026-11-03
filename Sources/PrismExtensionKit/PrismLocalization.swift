import Foundation
import PrismExtensionProtocol
import Synchronization

/// Prism's interface language, for writing list, status, widget, and message
/// text in it. Prism can run in a different language than macOS, and a
/// child process's `Bundle.module` follows macOS, so look strings up through
/// `prismLocalized`:
///
/// ```swift
/// String(localized: "Copied \(name)", bundle: .module.prismLocalized)
/// ```
///
/// Add a `Localizable.xcstrings` to the target's resources and
/// `defaultLocalization: "en"` to the package. A language you do not
/// translate shows your development language, never a neighboring one
/// (Traditional Chinese does not borrow Simplified).
public enum PrismLocalization {
    /// Prism's interface language (`en`, `zh-Hans`, `zh-Hant`). Inside a
    /// request it is what `initialize` sent; elsewhere, such as in a detached
    /// task, it comes from `PRISM_LANGUAGE`. Nil under a Prism that predates
    /// it, where `prismLocalized` follows macOS as before.
    @TaskLocal public static var language: String? = environmentLanguage

    static let environmentLanguage: String? = ProcessInfo.processInfo.environment["PRISM_LANGUAGE"]
        .flatMap { $0.isEmpty ? nil : $0 }

    /// The part of `bundle` that holds `language`'s strings: its matching
    /// `.lproj`, else its development language's, else a bundle with no
    /// strings, so lookups return the text written in code. Nil `language`
    /// returns `bundle`, which follows macOS.
    public static func bundle(_ bundle: Bundle, language: String? = Self.language) -> Bundle {
        guard let language else { return bundle }
        let key = CacheKey(path: bundle.bundleURL.path, language: language)
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let resolved = resolve(bundle, language: language)
        cache.withLock { $0[key] = resolved }
        return resolved
    }

    /// Prism's language with the user's region, for formatting numbers,
    /// dates, and lists alongside the translated text.
    public static var locale: Locale { locale(for: language) }

    public static func locale(for language: String?) -> Locale {
        guard let language else { return .current }
        let current = Locale.current
        var components = Locale.Components(locale: current)
        components.languageComponents = Locale.Language.Components(identifier: language)
        // Splitting off the language drops the region on some Foundation
        // versions; keep the user's formatting region either way.
        if components.region == nil { components.region = current.region }
        return Locale(components: components)
    }

    private static func resolve(_ bundle: Bundle, language: String) -> Bundle {
        let localizations = bundle.localizations
        let chosen = ExtensionLanguage.match(language, in: localizations)
            ?? bundle.developmentLocalization.flatMap { localizations.contains($0) ? $0 : nil }
            ?? (localizations.contains("en") ? "en" : nil)
        guard let chosen,
              let url = bundle.url(forResource: chosen, withExtension: "lproj"),
              let localized = Bundle(url: url) else { return untranslated ?? bundle }
        return localized
    }

    /// Looking strings up here returns the text written in code. A catalog
    /// with no development-language entries builds no `en.lproj`, and the
    /// bundle itself would pick a translation by the macOS language instead.
    /// `/var/empty` is the system's always-empty folder.
    private static let untranslated = Bundle(path: "/var/empty")

    private struct CacheKey: Hashable {
        let path: String
        let language: String
    }

    private static let cache = Mutex<[CacheKey: Bundle]>([:])
}

public extension Bundle {
    /// This bundle's strings in Prism's interface language; see
    /// `PrismLocalization`.
    var prismLocalized: Bundle { PrismLocalization.bundle(self) }
}
