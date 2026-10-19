import Foundation

/// Stable extension identity, independent of build variant. First-party
/// extensions use the reserved `prism.` namespace; Gallery extensions use
/// `<github-user>.<slug>`.
public struct ExtensionID: RawRepresentable, Hashable, Comparable, Codable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// Reserved for extensions that ship with Prism.
    public var isFirstParty: Bool { rawValue.hasPrefix("prism.") }

    public static func < (lhs: ExtensionID, rhs: ExtensionID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A tiled SF Symbol, matching the launcher's command icons, or an installed
/// app's icon.
public struct ExtensionIcon: Hashable, Codable, Sendable {
    /// How the symbol or image is drawn.
    public enum Style: String, Hashable, Codable, Sendable {
        /// On a tinted tile, as the launcher's command icons: the glyph is
        /// white on the tint (in dark appearance, tinted on a dark tile).
        case tile
        /// The glyph alone in the tint, for list rows where the color says
        /// something, such as a pull request's state.
        case glyph
    }

    public let symbol: String
    /// Semantic tile tint resolved by the presentation layer.
    public let tint: String
    /// A template image drawn instead of the symbol, such as a brand mark: a
    /// path inside the extension's folder to an SVG, PDF, or PNG of at most
    /// 512 KB. Anything Prism cannot use falls back to the symbol.
    public let image: String?
    /// An app's bundle identifier (`com.apple.Notes`): Prism draws that app's
    /// own icon, in color, for an extension that works with the app. Ahead of
    /// `image`; the symbol tile stands in when the app is not installed.
    public let app: String?
    /// Nil draws a symbol on a tile and an image alone in the surrounding
    /// color, as before styles existed.
    public let style: Style?

    public init(symbol: String, tint: String, image: String? = nil, app: String? = nil, style: Style? = nil) {
        self.symbol = symbol
        self.tint = tint
        self.image = image
        self.app = app
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case symbol, tint, image, app, style
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try container.decode(String.self, forKey: .symbol)
        tint = try container.decode(String.self, forKey: .tint)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        app = try container.decodeIfPresent(String.self, forKey: .app)
        // A style from a newer protocol draws the default way.
        style = (try? container.decodeIfPresent(String.self, forKey: .style)).flatMap { $0.flatMap(Style.init(rawValue:)) }
    }

    /// Whether the glyph sits on a tile: `.tile`, or no style with no image.
    public var isTiled: Bool {
        style.map { $0 == .tile } ?? (image == nil)
    }
}

public enum ExtensionCommandMode: String, Hashable, Codable, Sendable {
    /// Runs and reports a result without opening a view.
    case noView = "no-view"
    /// Opens a list scope (protocol v1; not yet rendered).
    case list
}

/// A statically declared command: it joins the root catalog on install and is
/// ranked without calling the extension.
public struct ExtensionCommand: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let mode: ExtensionCommandMode
    public let keywords: [String]
    /// Always-on aliases, like built-in command aliases.
    public let aliases: [String]
    /// Falls back to the extension icon.
    public let icon: ExtensionIcon?
    /// The row can subscribe to live status while visible.
    public let liveStatus: Bool
    /// The bundle ID of the app this `list` command searches. That app's
    /// root-search row then opens the command with Tab, as Spotlight searches
    /// inside an app.
    public let searchesApp: String?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        mode: ExtensionCommandMode = .noView,
        keywords: [String] = [],
        aliases: [String] = [],
        icon: ExtensionIcon? = nil,
        liveStatus: Bool = false,
        searchesApp: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.mode = mode
        self.keywords = keywords
        self.aliases = aliases
        self.icon = icon
        self.liveStatus = liveStatus
        self.searchesApp = searchesApp
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, mode, keywords, aliases, icon, liveStatus, searchesApp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        mode = try container.decode(ExtensionCommandMode.self, forKey: .mode)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        icon = try container.decodeIfPresent(ExtensionIcon.self, forKey: .icon)
        liveStatus = try container.decodeIfPresent(Bool.self, forKey: .liveStatus) ?? false
        searchesApp = try container.decodeIfPresent(String.self, forKey: .searchesApp)
    }
}

/// A JSON-compatible preference or state value.
public enum ExtensionValue: Hashable, Codable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case strings([String])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .strings(try container.decode([String].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .strings(value): try container.encode(value)
        }
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }
}

public enum ExtensionPreferenceType: String, Hashable, Codable, Sendable {
    case bool
    case text
    case secret
    case orderedList

    /// What a default of this type must be, for validation messages.
    public var defaultDescription: String {
        switch self {
        case .bool: "true or false"
        case .text, .secret: "string"
        case .orderedList: "list of strings"
        }
    }
}

/// A user preference rendered by Prism from its declaration.
public struct ExtensionPreference: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let type: ExtensionPreferenceType
    public let title: String
    public let caption: String?
    public let defaultValue: ExtensionValue?
    /// The settings group heading. Preferences sharing one are shown together,
    /// in the order the group first appears; those without one go under
    /// "Options".
    public let section: String?

    public init(
        id: String,
        type: ExtensionPreferenceType,
        title: String,
        caption: String? = nil,
        defaultValue: ExtensionValue? = nil,
        section: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.caption = caption
        self.defaultValue = defaultValue
        self.section = section
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, title, caption, section
        case defaultValue = "default"
    }
}

public enum ExtensionWidgetTemplate: String, Hashable, Codable, Sendable, CaseIterable {
    /// A small on/off card; clicking runs the content's toggle command.
    case toggleCard
    /// Quota cards: two items as rings, numbers, or labelled bars, or the
    /// first item alone as a ring or a number. Content is `ExtensionQuotaCard`.
    case quotaRings
    case quotaNumbers
    case quotaBars
    case quotaRing
    case quotaNumber

    public var isQuota: Bool { self != .toggleCard }

    /// How many items the card shows.
    public var quotaCapacity: Int {
        switch self {
        case .quotaRing, .quotaNumber: 1
        case .toggleCard: 0
        case .quotaRings, .quotaNumbers, .quotaBars: 2
        }
    }
}

public struct ExtensionWidget: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// One line for the Widgets settings rows.
    public let subtitle: String?
    public let template: ExtensionWidgetTemplate

    public init(id: String, title: String, subtitle: String? = nil, template: ExtensionWidgetTemplate) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.template = template
    }
}

/// A long-running program Prism starts and tracks for the extension, outside
/// the extension's own process tree.
public struct ExtensionTask: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    /// Absolute path; Prism only starts declared executables.
    public let executable: String
    /// Keeps running after Prism quits; Prism re-identifies it on the next launch.
    public let survivesHost: Bool

    public init(id: String, executable: String, survivesHost: Bool = false) {
        self.id = id
        self.executable = executable
        self.survivesHost = survivesHost
    }

    private enum CodingKeys: String, CodingKey {
        case id, executable, survivesHost
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        executable = try container.decode(String.self, forKey: .executable)
        survivesHost = try container.decodeIfPresent(Bool.self, forKey: .survivesHost) ?? false
    }
}

/// A folder outside the extension's data directory that it reads, such as
/// another app's library under `~/Library/Group Containers`. macOS protects
/// some of these; the extension offers a `grantFolder` action, and Prism asks
/// the user to choose the folder in an open panel. The user's choice lets
/// Prism, and the extensions it runs, read it from then on.
public struct ExtensionFolderGrant: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    /// Absolute, or relative to the home folder with a leading `~/`.
    public let path: String
    /// Why the extension needs it, shown in the open panel.
    public let reason: String

    public init(id: String, path: String, reason: String) {
        self.id = id
        self.path = path
        self.reason = reason
    }

    /// `path` with `~` expanded against `home`.
    public func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        guard path.hasPrefix("~/") else { return URL(fileURLWithPath: path, isDirectory: true) }
        return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
    }

    /// An absolute or `~/` path that names a folder below the root, without
    /// `.` or `..` steps.
    public var hasValidPath: Bool {
        let relative: Substring
        if path.hasPrefix("~/") {
            relative = path.dropFirst(2)
        } else if path.hasPrefix("/") {
            relative = path.dropFirst()
        } else {
            return false
        }
        let steps = relative.split(separator: "/", omittingEmptySubsequences: false)
        return steps.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

/// Declared at install time. Informational in v1; shaped so it can be enforced.
public struct ExtensionCapability: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let network: Self = "network"
    public static let readHomeFiles: Self = "readHomeFiles"
    public static let keychainRead: Self = "keychainRead"
    public static let spawnProcesses: Self = "spawnProcesses"
    public static let inspectProcesses: Self = "inspectProcesses"
    public static let hostTasks: Self = "hostTasks"
}

/// The declarative description of an extension: its `manifest.json`.
public struct ExtensionManifest: Hashable, Codable, Sendable, Identifiable {
    /// The newest protocol this Prism build understands.
    public static let supportedProtocolVersion = 1

    public let protocolVersion: Int
    public let id: ExtensionID
    public let name: String
    public let version: String
    public let author: String
    public let summary: String?
    public let minPrism: String?
    public let icon: ExtensionIcon
    /// Relative path inside the extension's folder; absent for an in-process
    /// extension (tests).
    public let executable: String?
    public let commands: [ExtensionCommand]
    public let preferences: [ExtensionPreference]
    public let widgets: [ExtensionWidget]
    public let tasks: [ExtensionTask]
    /// Folders the extension may ask the user to let it read.
    public let folders: [ExtensionFolderGrant]
    public let capabilities: [ExtensionCapability]

    public init(
        protocolVersion: Int = ExtensionManifest.supportedProtocolVersion,
        id: ExtensionID,
        name: String,
        version: String,
        author: String,
        summary: String? = nil,
        minPrism: String? = nil,
        icon: ExtensionIcon,
        executable: String? = nil,
        commands: [ExtensionCommand] = [],
        preferences: [ExtensionPreference] = [],
        widgets: [ExtensionWidget] = [],
        tasks: [ExtensionTask] = [],
        folders: [ExtensionFolderGrant] = [],
        capabilities: [ExtensionCapability] = []
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.summary = summary
        self.minPrism = minPrism
        self.icon = icon
        self.executable = executable
        self.commands = commands
        self.preferences = preferences
        self.widgets = widgets
        self.tasks = tasks
        self.folders = folders
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case id, name, version, author
        case summary = "description"
        case minPrism, icon, executable, commands, preferences, widgets, tasks, folders, capabilities
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        id = try container.decode(ExtensionID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        author = try container.decode(String.self, forKey: .author)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        minPrism = try container.decodeIfPresent(String.self, forKey: .minPrism)
        icon = try container.decodeIfPresent(ExtensionIcon.self, forKey: .icon)
            ?? ExtensionIcon(symbol: "puzzlepiece.extension", tint: "gray")
        executable = try container.decodeIfPresent(String.self, forKey: .executable)
        commands = try container.decodeIfPresent([ExtensionCommand].self, forKey: .commands) ?? []
        preferences = try container.decodeIfPresent([ExtensionPreference].self, forKey: .preferences) ?? []
        widgets = try container.decodeIfPresent([ExtensionWidget].self, forKey: .widgets) ?? []
        tasks = try container.decodeIfPresent([ExtensionTask].self, forKey: .tasks) ?? []
        folders = try container.decodeIfPresent([ExtensionFolderGrant].self, forKey: .folders) ?? []
        capabilities = try container.decodeIfPresent([ExtensionCapability].self, forKey: .capabilities) ?? []
    }

    public func command(id: String) -> ExtensionCommand? {
        commands.first { $0.id == id }
    }

    public func preference(id: String) -> ExtensionPreference? {
        preferences.first { $0.id == id }
    }

    /// Preferences grouped for settings: one group per `section`, in the order
    /// each first appears; preferences without a section share one untitled group.
    public var preferenceSections: [(title: String?, preferences: [ExtensionPreference])] {
        var groups: [(title: String?, preferences: [ExtensionPreference])] = []
        for preference in preferences {
            let title = preference.section.flatMap { $0.isEmpty ? nil : $0 }
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].preferences.append(preference)
            } else {
                groups.append((title, [preference]))
            }
        }
        return groups
    }

    public func widget(id: String) -> ExtensionWidget? {
        widgets.first { $0.id == id }
    }

    public func task(id: String) -> ExtensionTask? {
        tasks.first { $0.id == id }
    }

    public func folder(id: String) -> ExtensionFolderGrant? {
        folders.first { $0.id == id }
    }
}

public enum ExtensionManifestError: Error, Equatable, Sendable {
    case unsupportedProtocol(Int)
    case invalidID(String)
    case reservedID(String)
    case emptyField(String)
    case duplicateID(kind: String, id: String)
    case invalidItemID(kind: String, id: String)
    case invalidTaskExecutable(String)
    case invalidFolderPath(String)
    /// `searchesApp` on a command that is not a `list`, or an empty one.
    case invalidAppSearch(command: String)
    case invalidPreferenceDefault(id: String, type: ExtensionPreferenceType)
}

public extension ExtensionManifest {
    /// Structural checks shared by local import, Gallery installs, and the
    /// extensions repository's lint. `allowsReservedNamespace` admits Prism's
    /// own `prism.*` extensions.
    func validate(allowsReservedNamespace: Bool = false) throws {
        guard protocolVersion >= 1, protocolVersion <= Self.supportedProtocolVersion else {
            throw ExtensionManifestError.unsupportedProtocol(protocolVersion)
        }
        guard Self.isValidExtensionID(id.rawValue) else {
            throw ExtensionManifestError.invalidID(id.rawValue)
        }
        if id.isFirstParty, !allowsReservedNamespace {
            throw ExtensionManifestError.reservedID(id.rawValue)
        }
        for (field, value) in [("name", name), ("version", version), ("author", author)]
        where value.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ExtensionManifestError.emptyField(field)
        }
        try Self.validateItemIDs(commands.map(\.id), kind: "command")
        try Self.validateItemIDs(preferences.map(\.id), kind: "preference")
        try Self.validateItemIDs(widgets.map(\.id), kind: "widget")
        try Self.validateItemIDs(tasks.map(\.id), kind: "task")
        try Self.validateItemIDs(folders.map(\.id), kind: "folder")
        for command in commands where command.title.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ExtensionManifestError.emptyField("commands.\(command.id).title")
        }
        for command in commands {
            guard let app = command.searchesApp else { continue }
            guard command.mode == .list, !app.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ExtensionManifestError.invalidAppSearch(command: command.id)
            }
        }
        for task in tasks where !task.executable.hasPrefix("/") {
            throw ExtensionManifestError.invalidTaskExecutable(task.executable)
        }
        for folder in folders {
            guard folder.hasValidPath else { throw ExtensionManifestError.invalidFolderPath(folder.path) }
            if folder.reason.trimmingCharacters(in: .whitespaces).isEmpty {
                throw ExtensionManifestError.emptyField("folders.\(folder.id).reason")
            }
        }
        for preference in preferences {
            guard let value = preference.defaultValue else { continue }
            let matches = switch (preference.type, value) {
            case (.bool, .bool), (.text, .string), (.secret, .string), (.orderedList, .strings): true
            default: false
            }
            guard matches else {
                throw ExtensionManifestError.invalidPreferenceDefault(id: preference.id, type: preference.type)
            }
        }
    }

    /// Lowercase dot-separated segments of letters, digits, and hyphens, with
    /// at least two segments (`owner.slug`).
    static func isValidExtensionID(_ value: String) -> Bool {
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.first != "-" && segment.last != "-"
                && segment.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
        }
    }

    private static func validateItemIDs(_ ids: [String], kind: String) throws {
        var seen = Set<String>()
        for id in ids {
            let isValid = !id.isEmpty && id.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            }
            guard isValid else { throw ExtensionManifestError.invalidItemID(kind: kind, id: id) }
            guard seen.insert(id).inserted else {
                throw ExtensionManifestError.duplicateID(kind: kind, id: id)
            }
        }
    }
}
