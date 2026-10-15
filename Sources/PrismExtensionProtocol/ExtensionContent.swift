import Foundation

/// The outcome of `command.run`. Mirrors the launcher's action results so the
/// host can map it without interpretation.
///
/// Wire form: `{"kind": "completed" | "keepOpen" | "failed", "message": …,
/// "restoreFocus": …}`; `message` is optional for `completed` and
/// `restoreFocus` defaults to false.
public enum ExtensionCommandResult: Hashable, Codable, Sendable {
    /// Done: the launcher closes. `restoreFocus` returns to the summoning app.
    case completed(message: String?, restoreFocus: Bool)
    /// Done, and the launcher stays open to show the message.
    case keepOpen(message: String)
    case failed(message: String)

    private enum CodingKeys: String, CodingKey {
        case kind, message, restoreFocus
    }

    private enum Kind: String, Codable {
        case completed, keepOpen, failed
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let message = try container.decodeIfPresent(String.self, forKey: .message)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .completed:
            self = .completed(
                message: message,
                restoreFocus: try container.decodeIfPresent(Bool.self, forKey: .restoreFocus) ?? false
            )
        case .keepOpen:
            self = .keepOpen(message: message ?? "")
        case .failed:
            self = .failed(message: message ?? "The extension command failed.")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .completed(message, restoreFocus):
            try container.encode(Kind.completed, forKey: .kind)
            try container.encodeIfPresent(message, forKey: .message)
            try container.encode(restoreFocus, forKey: .restoreFocus)
        case let .keepOpen(message):
            try container.encode(Kind.keepOpen, forKey: .kind)
            try container.encode(message, forKey: .message)
        case let .failed(message):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }
}

/// Live state for a command's root-search row (`status.update`). Replaces the
/// row's static subtitle.
public struct ExtensionRowStatus: Hashable, Codable, Sendable {
    public enum Tone: String, Hashable, Codable, Sendable {
        case secondary
        case critical
    }

    public let text: String
    public let symbol: String?
    public let tone: Tone
    /// The extension keeps this current while the row is visible.
    public let isLive: Bool
    public let help: String?

    public init(
        text: String,
        symbol: String? = nil,
        tone: Tone = .secondary,
        isLive: Bool = false,
        help: String? = nil
    ) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
        self.isLive = isLive
        self.help = help
    }

    private enum CodingKeys: String, CodingKey {
        case text, symbol, tone, isLive, help
    }

    /// Everything but `text` may be omitted on the wire.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        tone = try container.decodeIfPresent(Tone.self, forKey: .tone) ?? .secondary
        isLive = try container.decodeIfPresent(Bool.self, forKey: .isLive) ?? false
        help = try container.decodeIfPresent(String.self, forKey: .help)
    }
}

/// Data for the `toggleCard` widget template.
public struct ExtensionToggleCard: Hashable, Codable, Sendable {
    public let title: String
    /// Short state line under the title ("On", "Off", "Error").
    public let status: String
    public let symbol: String
    /// Semantic tint for the filled "on" state.
    public let tint: String
    public let isOn: Bool
    public let isError: Bool
    public let help: String?
    public let accessibilityLabel: String?
    /// Command run when the card is clicked.
    public let toggleCommandID: String

    public init(
        title: String,
        status: String,
        symbol: String,
        tint: String,
        isOn: Bool,
        isError: Bool = false,
        help: String? = nil,
        accessibilityLabel: String? = nil,
        toggleCommandID: String
    ) {
        self.title = title
        self.status = status
        self.symbol = symbol
        self.tint = tint
        self.isOn = isOn
        self.isError = isError
        self.help = help
        self.accessibilityLabel = accessibilityLabel
        self.toggleCommandID = toggleCommandID
    }

    private enum CodingKeys: String, CodingKey {
        case title, status, symbol, tint, isOn, isError, help, accessibilityLabel, toggleCommandID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        status = try container.decode(String.self, forKey: .status)
        symbol = try container.decode(String.self, forKey: .symbol)
        tint = try container.decodeIfPresent(String.self, forKey: .tint) ?? "blue"
        isOn = try container.decode(Bool.self, forKey: .isOn)
        isError = try container.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        help = try container.decodeIfPresent(String.self, forKey: .help)
        accessibilityLabel = try container.decodeIfPresent(String.self, forKey: .accessibilityLabel)
        toggleCommandID = try container.decode(String.self, forKey: .toggleCommandID)
    }
}

/// Data for the quota templates: a few gauges, each with a short value.
/// Values arrive formatted; the card only lays them out.
public struct ExtensionQuotaCard: Hashable, Codable, Sendable {
    public let items: [ExtensionQuotaItem]
    /// Shown when there are no items ("No agents enabled").
    public let emptyText: String?
    /// Clicking the card runs this command, or opens it when it is a list.
    public let openCommandID: String?

    public init(items: [ExtensionQuotaItem], emptyText: String? = nil, openCommandID: String? = nil) {
        self.items = items
        self.emptyText = emptyText
        self.openCommandID = openCommandID
    }

    private enum CodingKeys: String, CodingKey {
        case items, emptyText, openCommandID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([ExtensionQuotaItem].self, forKey: .items) ?? []
        emptyText = try container.decodeIfPresent(String.self, forKey: .emptyText)
        openCommandID = try container.decodeIfPresent(String.self, forKey: .openCommandID)
    }
}

public struct ExtensionQuotaItem: Hashable, Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    /// Drawn inside the ring.
    public let icon: ExtensionIcon?
    /// `nil` when there is nothing to measure; the card shows `status` or
    /// `value` without a gauge.
    public let meter: ExtensionMeter?
    /// The figure: "42%", "$3.10".
    public let value: String
    /// A small line under the figure ("2h 13m").
    public let caption: String?
    /// A short problem ("Sign In") shown in place of the figure.
    public let status: String?

    public init(
        id: String,
        title: String,
        icon: ExtensionIcon? = nil,
        meter: ExtensionMeter? = nil,
        value: String,
        caption: String? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.meter = meter
        self.value = value
        self.caption = caption
        self.status = status
    }
}

/// `widget.load` result, one case per template. Wire form: the template's
/// fields plus `"template": "<name>"`.
public enum ExtensionWidgetContent: Hashable, Codable, Sendable {
    case toggleCard(ExtensionToggleCard)
    /// One of the quota templates.
    case quota(ExtensionWidgetTemplate, ExtensionQuotaCard)

    public var template: ExtensionWidgetTemplate {
        switch self {
        case .toggleCard: .toggleCard
        case let .quota(template, _): template
        }
    }

    private enum CodingKeys: String, CodingKey {
        case template
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let template = try container.decode(ExtensionWidgetTemplate.self, forKey: .template)
        if template.isQuota {
            self = .quota(template, try ExtensionQuotaCard(from: decoder))
        } else {
            self = .toggleCard(try ExtensionToggleCard(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(template, forKey: .template)
        switch self {
        case let .toggleCard(card): try card.encode(to: encoder)
        case let .quota(_, card): try card.encode(to: encoder)
        }
    }
}

/// Serializes protocol values the way the stdio transport will. In-process
/// extensions skip the transport; Debug builds and tests round-trip their
/// values through this to keep them representable on the wire.
public enum ExtensionWire {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }

    public static func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try decode(Value.self, from: encode(value))
    }
}
