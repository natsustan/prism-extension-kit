import Foundation

/// Which translation serves Prism's interface language. Shared by the host
/// (manifest text) and the Kit (an extension's own string catalog), so both
/// fall back the same way.
public enum ExtensionLanguage {
    /// The entry of `available` for `language`, or nil when none fits and the
    /// untranslated text should show. A language never borrows another
    /// script: with only `zh-Hans` on offer, `zh-Hant` gets nil, not
    /// Simplified Chinese.
    public static func match(_ language: String?, in available: some Collection<String>) -> String? {
        guard let language, !language.isEmpty else { return nil }
        let keys = available.filter { !$0.isEmpty && $0 != "Base" }.sorted()
        guard !keys.isEmpty else { return nil }
        // Foundation always picks one of the candidates, even an unrelated
        // one; English stands in for "none of them" so the base text wins.
        let candidates = keys.contains(fallback) ? keys : keys + [fallback]
        guard let picked = Bundle.preferredLocalizations(from: candidates, forPreferences: [language]).first,
              keys.contains(picked) else { return nil }
        return picked
    }

    private static let fallback = "en"
}

/// One language's translations of a manifest's display text, keyed by the
/// IDs the manifest declares. Every field is optional; whatever is missing
/// shows untranslated.
public struct ExtensionManifestLocalization: Hashable, Codable, Sendable {
    public struct Command: Hashable, Codable, Sendable {
        public var title: String?
        public var subtitle: String?
        /// Searched in addition to the command's own keywords.
        public var keywords: [String]

        public init(title: String? = nil, subtitle: String? = nil, keywords: [String] = []) {
            self.title = title
            self.subtitle = subtitle
            self.keywords = keywords
        }

        private enum CodingKeys: String, CodingKey { case title, subtitle, keywords }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try? container.decodeIfPresent(String.self, forKey: .title)
            subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)
            keywords = (try? container.decodeIfPresent([String].self, forKey: .keywords)) ?? []
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(subtitle, forKey: .subtitle)
            if !keywords.isEmpty { try container.encode(keywords, forKey: .keywords) }
        }
    }

    public struct Preference: Hashable, Codable, Sendable {
        public var title: String?
        public var caption: String?

        public init(title: String? = nil, caption: String? = nil) {
            self.title = title
            self.caption = caption
        }
    }

    public struct Widget: Hashable, Codable, Sendable {
        public var title: String?
        public var subtitle: String?

        public init(title: String? = nil, subtitle: String? = nil) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    public struct Folder: Hashable, Codable, Sendable {
        public var reason: String?

        public init(reason: String? = nil) {
            self.reason = reason
        }
    }

    public var name: String?
    /// The manifest's `description`.
    public var summary: String?
    public var commands: [String: Command]
    public var preferences: [String: Preference]
    /// Preference section headings, keyed by the untranslated heading.
    public var sections: [String: String]
    public var widgets: [String: Widget]
    public var folders: [String: Folder]

    public init(
        name: String? = nil,
        summary: String? = nil,
        commands: [String: Command] = [:],
        preferences: [String: Preference] = [:],
        sections: [String: String] = [:],
        widgets: [String: Widget] = [:],
        folders: [String: Folder] = [:]
    ) {
        self.name = name
        self.summary = summary
        self.commands = commands
        self.preferences = preferences
        self.sections = sections
        self.widgets = widgets
        self.folders = folders
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case summary = "description"
        case commands, preferences, sections, widgets, folders
    }

    /// A part Prism cannot read is left out rather than failing the manifest:
    /// translations only ever fall back to the untranslated text.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        summary = try? container.decodeIfPresent(String.self, forKey: .summary)
        commands = Self.lenient(container, .commands)
        preferences = Self.lenient(container, .preferences)
        sections = Self.lenient(container, .sections)
        widgets = Self.lenient(container, .widgets)
        folders = Self.lenient(container, .folders)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(summary, forKey: .summary)
        if !commands.isEmpty { try container.encode(commands, forKey: .commands) }
        if !preferences.isEmpty { try container.encode(preferences, forKey: .preferences) }
        if !sections.isEmpty { try container.encode(sections, forKey: .sections) }
        if !widgets.isEmpty { try container.encode(widgets, forKey: .widgets) }
        if !folders.isEmpty { try container.encode(folders, forKey: .folders) }
    }

    /// Each entry on its own: one malformed entry drops only itself.
    private static func lenient<Value: Decodable>(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> [String: Value] {
        guard let entries = try? container.decodeIfPresent([String: LenientValue<Value>].self, forKey: key) else {
            return [:]
        }
        return entries.compactMapValues(\.value)
    }

    /// Lists every translated string, for checks such as empty text.
    public var allText: [(field: String, text: String)] {
        var fields = [(String, String)]()
        if let name { fields.append(("name", name)) }
        if let summary { fields.append(("description", summary)) }
        for (id, command) in commands.sorted(by: { $0.key < $1.key }) {
            if let title = command.title { fields.append(("commands.\(id).title", title)) }
            if let subtitle = command.subtitle { fields.append(("commands.\(id).subtitle", subtitle)) }
            for keyword in command.keywords { fields.append(("commands.\(id).keywords", keyword)) }
        }
        for (id, preference) in preferences.sorted(by: { $0.key < $1.key }) {
            if let title = preference.title { fields.append(("preferences.\(id).title", title)) }
            if let caption = preference.caption { fields.append(("preferences.\(id).caption", caption)) }
        }
        for (section, text) in sections.sorted(by: { $0.key < $1.key }) {
            fields.append(("sections.\(section)", text))
        }
        for (id, widget) in widgets.sorted(by: { $0.key < $1.key }) {
            if let title = widget.title { fields.append(("widgets.\(id).title", title)) }
            if let subtitle = widget.subtitle { fields.append(("widgets.\(id).subtitle", subtitle)) }
        }
        for (id, folder) in folders.sorted(by: { $0.key < $1.key }) {
            if let reason = folder.reason { fields.append(("folders.\(id).reason", reason)) }
        }
        return fields
    }
}

/// Decodes to nil instead of throwing.
struct LenientValue<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// A manifest's text as Prism shows it in one language. Identity stays on
/// the manifest: IDs, settings anchors, and section grouping use the
/// untranslated text, and only display goes through here.
public struct ExtensionDisplayText: Hashable, Sendable {
    /// The `localizations` key in use; nil shows the untranslated text.
    public let language: String?
    public let name: String
    public let summary: String?
    private let entry: ExtensionManifestLocalization?

    init(manifest: ExtensionManifest, language: String?) {
        let key = ExtensionLanguage.match(language, in: manifest.localizations.keys)
        let entry = key.flatMap { manifest.localizations[$0] }
        self.language = key
        self.entry = entry
        name = Self.pick(entry?.name, manifest.name)
        summary = Self.pick(entry?.summary, manifest.summary)
    }

    public func title(of command: ExtensionCommand) -> String {
        Self.pick(entry?.commands[command.id]?.title, command.title)
    }

    public func subtitle(of command: ExtensionCommand) -> String? {
        Self.pick(entry?.commands[command.id]?.subtitle, command.subtitle)
    }

    /// The translated keywords only; the command's own stay searchable.
    public func keywords(of command: ExtensionCommand) -> [String] {
        (entry?.commands[command.id]?.keywords ?? []).compactMap(Self.nonEmpty)
    }

    public func title(of preference: ExtensionPreference) -> String {
        Self.pick(entry?.preferences[preference.id]?.title, preference.title)
    }

    public func caption(of preference: ExtensionPreference) -> String? {
        Self.pick(entry?.preferences[preference.id]?.caption, preference.caption)
    }

    /// A preference section heading, given as the manifest writes it.
    public func section(_ heading: String) -> String {
        Self.pick(entry?.sections[heading], heading)
    }

    public func title(of widget: ExtensionWidget) -> String {
        Self.pick(entry?.widgets[widget.id]?.title, widget.title)
    }

    public func subtitle(of widget: ExtensionWidget) -> String? {
        Self.pick(entry?.widgets[widget.id]?.subtitle, widget.subtitle)
    }

    public func reason(of folder: ExtensionFolderGrant) -> String {
        Self.pick(entry?.folders[folder.id]?.reason, folder.reason)
    }

    private static func pick(_ translated: String?, _ base: String) -> String {
        translated.flatMap(nonEmpty) ?? base
    }

    private static func pick(_ translated: String?, _ base: String?) -> String? {
        translated.flatMap(nonEmpty) ?? base
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

public extension ExtensionManifest {
    /// Display text in `language`, Prism's interface language; nil or a
    /// language the manifest does not translate shows the untranslated text.
    func displayText(for language: String?) -> ExtensionDisplayText {
        ExtensionDisplayText(manifest: self, language: language)
    }

    /// Translations that name a command, preference, section, widget, or
    /// folder the manifest does not declare, one line each, for lint.
    func unknownLocalizationReferences() -> [String] {
        let commandIDs = Set(commands.map(\.id))
        let preferenceIDs = Set(preferences.map(\.id))
        let sectionNames = Set(preferences.compactMap(\.section))
        let widgetIDs = Set(widgets.map(\.id))
        let folderIDs = Set(folders.map(\.id))
        var problems = [String]()
        for (language, entry) in localizations.sorted(by: { $0.key < $1.key }) {
            func check(_ ids: some Collection<String>, _ known: Set<String>, _ kind: String) {
                for id in ids.sorted() where !known.contains(id) {
                    problems.append("localizations.\(language).\(kind).\(id) names no \(kind.dropLast()) in the manifest")
                }
            }
            check(entry.commands.keys, commandIDs, "commands")
            check(entry.preferences.keys, preferenceIDs, "preferences")
            check(entry.sections.keys, sectionNames, "sections")
            check(entry.widgets.keys, widgetIDs, "widgets")
            check(entry.folders.keys, folderIDs, "folders")
        }
        return problems
    }
}
