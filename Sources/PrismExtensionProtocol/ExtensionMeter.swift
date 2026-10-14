import Foundation

/// Dates travel as Unix seconds, which `date +%s` can write. Whole seconds
/// survive the round trip through `Date` exactly.
enum ExtensionWireDate {
    static func date(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds.rounded())
    }

    static func seconds(_ date: Date) -> Double {
        date.timeIntervalSince1970.rounded()
    }

    static func rounded(_ date: Date?) -> Date? {
        date.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded()) }
    }
}

extension KeyedDecodingContainer {
    func decodeDateIfPresent(forKey key: Key) throws -> Date? {
        try decodeIfPresent(Double.self, forKey: key).map(ExtensionWireDate.date)
    }
}

extension KeyedEncodingContainer {
    mutating func encodeDateIfPresent(_ date: Date?, forKey key: Key) throws {
        try encodeIfPresent(date.map(ExtensionWireDate.seconds), forKey: key)
    }
}

/// How urgent a value reads. Prism picks the colors, so every extension's
/// warnings look alike.
public enum ExtensionTone: String, Hashable, Codable, Sendable {
    case normal
    case warning
    case critical
}

/// A gauge: how full something is, and when it resets. The extension decides
/// what the fraction means (used or left) and how urgent it is; Prism draws a
/// ring in list rows and widgets, and a bar in the detail pane.
///
/// Wire form: `{"fraction": 0.42, "tone": "warning", "resetsAt": 1760000000}`.
public struct ExtensionMeter: Hashable, Codable, Sendable {
    /// 0...1; values outside are clamped.
    public let fraction: Double
    public let tone: ExtensionTone
    /// When the measured window starts over. Prism shows a live countdown.
    public let resetsAt: Date?

    public init(fraction: Double, tone: ExtensionTone = .normal, resetsAt: Date? = nil) {
        self.fraction = Self.clamp(fraction)
        self.tone = tone
        self.resetsAt = ExtensionWireDate.rounded(resetsAt)
    }

    private enum CodingKeys: String, CodingKey {
        case fraction, tone, resetsAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fraction = Self.clamp(try container.decode(Double.self, forKey: .fraction))
        tone = try container.decodeIfPresent(ExtensionTone.self, forKey: .tone) ?? .normal
        resetsAt = try container.decodeDateIfPresent(forKey: .resetsAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fraction, forKey: .fraction)
        try container.encode(tone, forKey: .tone)
        try container.encodeDateIfPresent(resetsAt, forKey: .resetsAt)
    }

    private static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

/// A one-line callout in the detail pane: a failed refresh, a missing sign-in.
public struct ExtensionNotice: Hashable, Codable, Sendable {
    public let text: String
    public let symbol: String?
    public let tone: ExtensionTone

    public init(text: String, symbol: String? = nil, tone: ExtensionTone = .warning) {
        self.text = text
        self.symbol = symbol
        self.tone = tone
    }

    private enum CodingKeys: String, CodingKey {
        case text, symbol, tone
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        tone = try container.decodeIfPresent(ExtensionTone.self, forKey: .tone) ?? .warning
    }
}

/// A titled block of rows in the detail pane's scrolling content.
public struct ExtensionDetailSection: Hashable, Codable, Sendable {
    public let title: String?
    public let rows: [ExtensionMetadataRow]

    public init(title: String? = nil, rows: [ExtensionMetadataRow]) {
        self.title = title
        self.rows = rows
    }
}
