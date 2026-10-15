import Foundation

/// `list.load` result: what a `list` command's scope shows.
///
/// Wire form: `{"items": [...], "filtering": "prism" | "extension", ...}`.
/// Every field but `items` may be omitted. Item and action IDs must be
/// unique and stable across reloads: Prism restores the selection by ID and
/// performs actions by ID, never by position.
public struct ExtensionList: Hashable, Codable, Sendable {
    /// Larger lists are cut to this many items.
    public static let maximumItems = 1_000

    /// Who narrows the list as the user types.
    public enum Filtering: String, Hashable, Codable, Sendable {
        /// Prism ranks the loaded items itself (title, subtitle, keywords).
        case prism
        /// Prism reloads the list with each query, after a short pause.
        case `extension`
    }

    public let items: [ExtensionListItem]
    public let filtering: Filtering
    public let searchPlaceholder: String?
    /// Choices for the ⌘P filter menu. The chosen ID comes back in
    /// `list.load`'s `filter`.
    public let filters: [ExtensionListFilter]
    /// Shown when there are no items (or none match).
    public let emptyMessage: ExtensionListMessage?
    /// A detail pane beside the list, filled from each item's `detail` or,
    /// when that is missing, from `detail.load`. On by default when any item
    /// has inline detail.
    public let showsDetail: Bool
    /// When the data was fetched, to the second. Prism shows its age when
    /// it is retained.
    public let fetchedAt: Date?
    /// Why the data may be stale or partial (for example, a failed refresh
    /// that kept cached items). Shown beside the items, not instead of them.
    public let error: String?

    public init(
        items: [ExtensionListItem],
        filtering: Filtering = .prism,
        searchPlaceholder: String? = nil,
        filters: [ExtensionListFilter] = [],
        emptyMessage: ExtensionListMessage? = nil,
        showsDetail: Bool? = nil,
        fetchedAt: Date? = nil,
        error: String? = nil
    ) {
        self.items = items
        self.filtering = filtering
        self.searchPlaceholder = searchPlaceholder
        self.filters = filters
        self.emptyMessage = emptyMessage
        self.showsDetail = showsDetail ?? items.contains { $0.detail != nil }
        self.fetchedAt = ExtensionWireDate.rounded(fetchedAt)
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case items, filtering, searchPlaceholder, filters, emptyMessage, showsDetail, fetchedAt, error
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([ExtensionListItem].self, forKey: .items)
        filtering = try container.decodeIfPresent(Filtering.self, forKey: .filtering) ?? .prism
        searchPlaceholder = try container.decodeIfPresent(String.self, forKey: .searchPlaceholder)
        filters = try container.decodeIfPresent([ExtensionListFilter].self, forKey: .filters) ?? []
        emptyMessage = try container.decodeIfPresent(ExtensionListMessage.self, forKey: .emptyMessage)
        showsDetail = try container.decodeIfPresent(Bool.self, forKey: .showsDetail)
            ?? items.contains { $0.detail != nil }
        fetchedAt = try container.decodeDateIfPresent(forKey: .fetchedAt)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    /// `fetchedAt` travels as Unix seconds, which `date +%s` can write.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encode(filtering, forKey: .filtering)
        try container.encodeIfPresent(searchPlaceholder, forKey: .searchPlaceholder)
        try container.encode(filters, forKey: .filters)
        try container.encodeIfPresent(emptyMessage, forKey: .emptyMessage)
        try container.encode(showsDetail, forKey: .showsDetail)
        try container.encodeDateIfPresent(fetchedAt, forKey: .fetchedAt)
        try container.encodeIfPresent(error, forKey: .error)
    }

    /// The list Prism keeps: at most `maximumItems`, without repeated item
    /// IDs or repeated action IDs within an item (the first one wins).
    public func normalized() -> ExtensionList {
        var seen = Set<String>()
        var kept = [ExtensionListItem]()
        for item in items where kept.count < Self.maximumItems && seen.insert(item.id).inserted {
            kept.append(item.normalized())
        }
        var filterIDs = Set<String>()
        return ExtensionList(
            items: kept, filtering: filtering, searchPlaceholder: searchPlaceholder,
            filters: filters.filter { filterIDs.insert($0.id).inserted },
            emptyMessage: emptyMessage, showsDetail: showsDetail, fetchedAt: fetchedAt, error: error
        )
    }
}

public struct ExtensionListItem: Hashable, Codable, Sendable, Identifiable {
    public static let maximumActions = 20

    public let id: String
    public let title: String
    public let subtitle: String?
    public let icon: ExtensionIcon?
    /// Short trailing labels: a count, a date, a state.
    public let accessories: [ExtensionListAccessory]
    /// Extra words Prism matches when it filters the list.
    public let keywords: [String]
    /// Items with the same section are grouped under that heading, in the
    /// order sections first appear.
    public let section: String?
    /// The detail pane's content, when known up front.
    public let detail: ExtensionDetail?
    /// The first action runs on Return; all of them are in the ⌘K panel.
    public let actions: [ExtensionAction]
    /// This item is being refreshed; Prism shows a spinner beside it.
    public let isLoading: Bool

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: ExtensionIcon? = nil,
        accessories: [ExtensionListAccessory] = [],
        keywords: [String] = [],
        section: String? = nil,
        detail: ExtensionDetail? = nil,
        actions: [ExtensionAction] = [],
        isLoading: Bool = false
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.accessories = accessories
        self.keywords = keywords
        self.section = section
        self.detail = detail
        self.actions = actions
        self.isLoading = isLoading
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, icon, accessories, keywords, section, detail, actions, isLoading
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        icon = try container.decodeIfPresent(ExtensionIcon.self, forKey: .icon)
        accessories = try container.decodeIfPresent([ExtensionListAccessory].self, forKey: .accessories) ?? []
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        section = try container.decodeIfPresent(String.self, forKey: .section)
        detail = try container.decodeIfPresent(ExtensionDetail.self, forKey: .detail)
        actions = try container.decodeIfPresent([ExtensionAction].self, forKey: .actions) ?? []
        isLoading = try container.decodeIfPresent(Bool.self, forKey: .isLoading) ?? false
    }

    /// The default action: what Return does.
    public var primaryAction: ExtensionAction? { actions.first }

    public func action(id: String) -> ExtensionAction? {
        actions.first { $0.id == id }
    }

    func normalized() -> ExtensionListItem {
        var seen = Set<String>()
        let kept = actions.filter { seen.insert($0.id).inserted }.prefix(Self.maximumActions)
        return ExtensionListItem(
            id: id, title: title, subtitle: subtitle, icon: icon, accessories: accessories,
            keywords: keywords, section: section, detail: detail, actions: Array(kept), isLoading: isLoading
        )
    }
}

/// A trailing label on a list item.
public struct ExtensionListAccessory: Hashable, Codable, Sendable {
    public let text: String?
    public let symbol: String?
    /// Semantic tint, as for icons. Secondary when omitted.
    public let tint: String?
    public let help: String?
    /// A small ring before the text.
    public let meter: ExtensionMeter?

    public init(
        text: String? = nil, symbol: String? = nil, tint: String? = nil, help: String? = nil,
        meter: ExtensionMeter? = nil
    ) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.help = help
        self.meter = meter
    }
}

/// One choice in the ⌘P filter menu.
public struct ExtensionListFilter: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let symbol: String?

    public init(id: String, title: String, symbol: String? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
    }
}

/// A full-pane message in place of items: an empty state, an error, or a
/// sign-in prompt.
public struct ExtensionListMessage: Hashable, Codable, Sendable {
    public let title: String
    public let message: String?
    public let symbol: String?

    public init(title: String, message: String? = nil, symbol: String? = nil) {
        self.title = title
        self.message = message
        self.symbol = symbol
    }
}

/// The detail pane for one item (`detail.load`, or inline in the item):
/// Markdown text above labelled metadata rows.
public struct ExtensionDetail: Hashable, Codable, Sendable {
    /// An optional header above the content.
    public let title: String?
    public let subtitle: String?
    public let icon: ExtensionIcon?
    /// When this item's data was fetched; Prism shows a live "Updated …" line.
    public let updatedAt: Date?
    public let notice: ExtensionNotice?
    public let markdown: String?
    /// Blocks of rows under the Markdown; rows can carry meters.
    public let sections: [ExtensionDetailSection]
    /// The Information block pinned to the bottom of the pane.
    public let metadata: [ExtensionMetadataRow]

    public init(
        title: String? = nil,
        subtitle: String? = nil,
        icon: ExtensionIcon? = nil,
        updatedAt: Date? = nil,
        notice: ExtensionNotice? = nil,
        markdown: String? = nil,
        sections: [ExtensionDetailSection] = [],
        metadata: [ExtensionMetadataRow] = []
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.updatedAt = ExtensionWireDate.rounded(updatedAt)
        self.notice = notice
        self.markdown = markdown
        self.sections = sections
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, icon, updatedAt, notice, markdown, sections, metadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        icon = try container.decodeIfPresent(ExtensionIcon.self, forKey: .icon)
        updatedAt = try container.decodeDateIfPresent(forKey: .updatedAt)
        notice = try container.decodeIfPresent(ExtensionNotice.self, forKey: .notice)
        markdown = try container.decodeIfPresent(String.self, forKey: .markdown)
        sections = try container.decodeIfPresent([ExtensionDetailSection].self, forKey: .sections) ?? []
        metadata = try container.decodeIfPresent([ExtensionMetadataRow].self, forKey: .metadata) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeDateIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(notice, forKey: .notice)
        try container.encodeIfPresent(markdown, forKey: .markdown)
        try container.encode(sections, forKey: .sections)
        try container.encode(metadata, forKey: .metadata)
    }

    /// Nothing to show: no header, text, or rows.
    public var isEmpty: Bool {
        title == nil && notice == nil && (markdown ?? "").isEmpty && sections.allSatisfy(\.rows.isEmpty)
            && metadata.isEmpty
    }
}

/// A labelled value. In detail sections a row can carry a meter (drawn as a
/// bar with a reset countdown) or a date (drawn as a date and a countdown).
public struct ExtensionMetadataRow: Hashable, Codable, Sendable {
    public enum Style: String, Hashable, Codable, Sendable {
        case plain
        /// The value reads as a state pill ("Disabled").
        case badge
    }

    public let label: String
    public let value: String
    public let symbol: String?
    public let style: Style
    public let meter: ExtensionMeter?
    public let date: Date?

    public init(
        label: String,
        value: String = "",
        symbol: String? = nil,
        style: Style = .plain,
        meter: ExtensionMeter? = nil,
        date: Date? = nil
    ) {
        self.label = label
        self.value = value
        self.symbol = symbol
        self.style = style
        self.meter = meter
        self.date = ExtensionWireDate.rounded(date)
    }

    private enum CodingKeys: String, CodingKey {
        case label, value, symbol, style, meter, date
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .plain
        meter = try container.decodeIfPresent(ExtensionMeter.self, forKey: .meter)
        date = try container.decodeDateIfPresent(forKey: .date)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(label, forKey: .label)
        try container.encode(value, forKey: .value)
        try container.encodeIfPresent(symbol, forKey: .symbol)
        try container.encode(style, forKey: .style)
        try container.encodeIfPresent(meter, forKey: .meter)
        try container.encodeDateIfPresent(date, forKey: .date)
    }
}

/// Something the user can do with an item.
///
/// Wire form: `{"id", "title", "kind": "perform" | "copy" | "open", ...}`.
/// `perform` (the default) sends `action.perform` to the extension; `copy`
/// and `open` are carried out by Prism without a round trip.
public struct ExtensionAction: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case perform
        /// Copies `text` to the clipboard and closes the launcher.
        case copy(text: String)
        /// Opens an `http`, `https`, or `file` URL with its default app.
        case open(url: URL)
    }

    public enum Style: String, Hashable, Codable, Sendable {
        case regular
        /// Asks for confirmation before it runs.
        case destructive
    }

    public let id: String
    public let title: String
    public let symbol: String?
    public let kind: Kind
    public let style: Style
    /// A key equivalent such as `"cmd+d"` or `"cmd+shift+c"`.
    public let shortcut: ExtensionShortcut?
    /// The confirmation's explanation. Destructive actions always confirm;
    /// any other action with a message confirms too.
    public let confirmationMessage: String?

    public init(
        id: String,
        title: String,
        symbol: String? = nil,
        kind: Kind = .perform,
        style: Style = .regular,
        shortcut: ExtensionShortcut? = nil,
        confirmationMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.kind = kind
        self.style = style
        self.shortcut = shortcut
        self.confirmationMessage = confirmationMessage
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, symbol, kind, text, url, style, shortcut, confirmationMessage
    }

    private enum KindName: String, Codable {
        case perform, copy, open
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        switch try container.decodeIfPresent(KindName.self, forKey: .kind) ?? .perform {
        case .perform:
            kind = .perform
        case .copy:
            kind = .copy(text: try container.decode(String.self, forKey: .text))
        case .open:
            let string = try container.decode(String.self, forKey: .url)
            guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "file"].contains(scheme) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .url, in: container, debugDescription: "Only http, https, and file URLs open."
                )
            }
            kind = .open(url: url)
        }
        style = try container.decodeIfPresent(Style.self, forKey: .style) ?? .regular
        // An unusable shortcut is dropped rather than failing the whole list.
        shortcut = (try? container.decodeIfPresent(String.self, forKey: .shortcut))
            .flatMap { $0.flatMap(ExtensionShortcut.init) }
        confirmationMessage = try container.decodeIfPresent(String.self, forKey: .confirmationMessage)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(symbol, forKey: .symbol)
        switch kind {
        case .perform:
            try container.encode(KindName.perform, forKey: .kind)
        case let .copy(text):
            try container.encode(KindName.copy, forKey: .kind)
            try container.encode(text, forKey: .text)
        case let .open(url):
            try container.encode(KindName.open, forKey: .kind)
            try container.encode(url.absoluteString, forKey: .url)
        }
        try container.encode(style, forKey: .style)
        try container.encodeIfPresent(shortcut?.description, forKey: .shortcut)
        try container.encodeIfPresent(confirmationMessage, forKey: .confirmationMessage)
    }
}

/// An action's key equivalent. It needs ⌘ or ⌃ so it never takes a key the
/// user is typing into the search field; written `"cmd+shift+c"`.
public struct ExtensionShortcut: Hashable, Sendable, CustomStringConvertible {
    public enum Modifier: String, Hashable, CaseIterable, Sendable {
        case ctrl, option, shift, cmd
    }

    /// A lowercase letter or digit, or a named key (`"return"`, `"delete"`).
    public let key: String
    public let modifiers: Set<Modifier>

    public static let namedKeys: Set<String> = ["return", "delete", "space", "tab", "up", "down", "left", "right"]

    public init?(_ description: String) {
        var parts = description.lowercased().split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let key = parts.popLast() else { return nil }
        let aliases: [String: Modifier] = [
            "cmd": .cmd, "command": .cmd, "ctrl": .ctrl, "control": .ctrl,
            "opt": .option, "option": .option, "alt": .option, "shift": .shift,
        ]
        var modifiers = Set<Modifier>()
        for part in parts {
            guard let modifier = aliases[part], modifiers.insert(modifier).inserted else { return nil }
        }
        let isCharacter = key.count == 1 && key.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0))
        }
        guard isCharacter || Self.namedKeys.contains(key),
              modifiers.contains(.cmd) || modifiers.contains(.ctrl) else { return nil }
        self.key = key
        self.modifiers = modifiers
    }

    public var description: String {
        (Modifier.allCases.filter(modifiers.contains).map(\.rawValue) + [key]).joined(separator: "+")
    }
}

/// `action.perform` result: a command result, plus whether the list should
/// reload because the action changed it.
///
/// Wire form: the command result's fields plus an optional `"reload": true`.
public struct ExtensionActionResult: Hashable, Codable, Sendable {
    public let result: ExtensionCommandResult
    public let reload: Bool

    public init(_ result: ExtensionCommandResult, reload: Bool = false) {
        self.result = result
        self.reload = reload
    }

    private enum CodingKeys: String, CodingKey {
        case reload
    }

    public init(from decoder: any Decoder) throws {
        result = try ExtensionCommandResult(from: decoder)
        reload = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Bool.self, forKey: .reload) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        try result.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        if reload { try container.encode(true, forKey: .reload) }
    }
}
