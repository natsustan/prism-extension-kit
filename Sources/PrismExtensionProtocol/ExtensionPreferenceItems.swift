import Foundation

/// One entry of an `orderedList` preference, as the extension describes it
/// (`preferences.items`). The user's order and switches are kept by Prism;
/// `isOn` is the switch's default until the user touches it.
public struct ExtensionPreferenceItem: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let icon: ExtensionIcon?
    /// A short status beside the switch ("Configured").
    public let badge: String?
    public let isOn: Bool

    public init(id: String, title: String, icon: ExtensionIcon? = nil, badge: String? = nil, isOn: Bool = true) {
        self.id = id
        self.title = title
        self.icon = icon
        self.badge = badge
        self.isOn = isOn
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, icon, badge, isOn
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        icon = try container.decodeIfPresent(ExtensionIcon.self, forKey: .icon)
        badge = try container.decodeIfPresent(String.self, forKey: .badge)
        isOn = try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
    }
}

/// `preferences.items` result.
public struct ExtensionPreferenceItems: Hashable, Codable, Sendable {
    public let items: [ExtensionPreferenceItem]

    public init(items: [ExtensionPreferenceItem]) {
        self.items = items
    }
}

/// The value of an `orderedList` preference: every item the user has
/// ordered, in order, with its switch. Stored and sent as strings, one per
/// item, with a leading `-` for an item that is off: `["codex", "-grok"]`.
/// Items the value does not mention keep their default switch and come last,
/// in the extension's order.
public struct ExtensionOrderedList: Hashable, Sendable {
    public struct Entry: Hashable, Sendable {
        public let id: String
        public let isOn: Bool

        public init(id: String, isOn: Bool) {
            self.id = id
            self.isOn = isOn
        }
    }

    public let entries: [Entry]

    public init(_ entries: [Entry]) {
        var seen = Set<String>()
        self.entries = entries.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    public init(value: ExtensionValue?) {
        guard case let .strings(strings)? = value else {
            self.init([])
            return
        }
        self.init(strings.map { string in
            string.hasPrefix("-")
                ? Entry(id: String(string.dropFirst()), isOn: false)
                : Entry(id: string, isOn: true)
        })
    }

    public var value: ExtensionValue {
        .strings(entries.map { $0.isOn ? $0.id : "-\($0.id)" })
    }

    /// The user's arrangement applied to the extension's current items:
    /// stored order first, then new items in their own order; stored entries
    /// for items that no longer exist are dropped.
    public func resolved(with items: [ExtensionPreferenceItem]) -> [Entry] {
        let known = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stored = entries.filter { known[$0.id] != nil }
        let storedIDs = Set(stored.map(\.id))
        return stored + items.filter { !storedIDs.contains($0.id) }.map { Entry(id: $0.id, isOn: $0.isOn) }
    }

    /// The IDs that are on, in order.
    public func enabledIDs(with items: [ExtensionPreferenceItem]) -> [String] {
        resolved(with: items).filter(\.isOn).map(\.id)
    }

    /// The arrangement after switching one item.
    public func setting(_ id: String, isOn: Bool, items: [ExtensionPreferenceItem]) -> ExtensionOrderedList {
        ExtensionOrderedList(resolved(with: items).map { $0.id == id ? Entry(id: id, isOn: isOn) : $0 })
    }

    /// The arrangement after moving one item to another's place.
    public func moving(_ id: String, onto target: String, items: [ExtensionPreferenceItem]) -> ExtensionOrderedList {
        var resolved = resolved(with: items)
        guard id != target,
              let source = resolved.firstIndex(where: { $0.id == id }),
              let destination = resolved.firstIndex(where: { $0.id == target }) else { return self }
        let entry = resolved.remove(at: source)
        resolved.insert(entry, at: destination)
        return ExtensionOrderedList(resolved)
    }
}
