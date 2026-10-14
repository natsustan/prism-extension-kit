import Foundation

/// Any JSON value. Message envelopes carry params and results in this form;
/// each method decodes its own typed shape from it.
public enum ExtensionJSON: Hashable, Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ExtensionJSON])
    case object([String: ExtensionJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ExtensionJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: ExtensionJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// Re-encodes a typed value as JSON.
    public init<Value: Encodable>(encoding value: Value) throws {
        self = try ExtensionWire.decode(ExtensionJSON.self, from: ExtensionWire.encode(value))
    }

    /// Decodes this JSON as a typed value.
    public func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try ExtensionWire.decode(type, from: ExtensionWire.encode(self))
    }
}

public struct ExtensionRPCError: Hashable, Codable, Sendable, Error {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// One NDJSON line. A request has `id` and `method`; a response has `id` and
/// `result` or `error`; a notification has `method` and no `id`.
public struct ExtensionMessage: Hashable, Codable, Sendable {
    public var id: Int?
    public var method: String?
    public var params: ExtensionJSON?
    public var result: ExtensionJSON?
    public var error: ExtensionRPCError?

    public init(
        id: Int? = nil,
        method: String? = nil,
        params: ExtensionJSON? = nil,
        result: ExtensionJSON? = nil,
        error: ExtensionRPCError? = nil
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
    }

    public enum Kind: Equatable, Sendable {
        case request(id: Int, method: String)
        case response(id: Int)
        case notification(method: String)
        case invalid
    }

    public var kind: Kind {
        switch (id, method) {
        case let (id?, method?): .request(id: id, method: method)
        case let (id?, nil): .response(id: id)
        case let (nil, method?): .notification(method: method)
        case (nil, nil): .invalid
        }
    }

    public static func request<Params: Encodable>(id: Int, method: String, params: Params) throws -> Self {
        ExtensionMessage(id: id, method: method, params: try ExtensionJSON(encoding: params))
    }

    public static func notification<Params: Encodable>(method: String, params: Params) throws -> Self {
        ExtensionMessage(method: method, params: try ExtensionJSON(encoding: params))
    }

    /// The encoded line, newline included.
    public func line() throws -> Data {
        var data = try ExtensionWire.encode(self)
        data.append(0x0A)
        return data
    }
}

/// Method names of protocol v1 that this Prism build speaks.
public enum ExtensionMethod {
    // Prism → extension
    public static let initialize = "initialize"
    public static let commandRun = "command.run"
    public static let widgetLoad = "widget.load"
    public static let statusSubscribe = "status.subscribe"
    public static let statusUnsubscribe = "status.unsubscribe"
    public static let cancel = "cancel"
    public static let willTerminate = "willTerminate"
    // Extension → Prism
    public static let statusUpdate = "status.update"
    public static let stateWrite = "state.write"
    public static let taskStart = "task.start"
    public static let log = "log"
}

public struct ExtensionInitializeParams: Hashable, Codable, Sendable {
    public let protocolVersion: Int
    public let prismVersion: String
    public let extensionID: ExtensionID
    public let preferences: [String: ExtensionValue]
    public let state: [String: ExtensionValue]

    public init(
        protocolVersion: Int = ExtensionManifest.supportedProtocolVersion,
        prismVersion: String,
        extensionID: ExtensionID,
        preferences: [String: ExtensionValue],
        state: [String: ExtensionValue]
    ) {
        self.protocolVersion = protocolVersion
        self.prismVersion = prismVersion
        self.extensionID = extensionID
        self.preferences = preferences
        self.state = state
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case prismVersion, extensionID, preferences, state
    }
}

public struct ExtensionCommandParams: Hashable, Codable, Sendable {
    public let commandID: String

    public init(commandID: String) { self.commandID = commandID }
}

public struct ExtensionWidgetParams: Hashable, Codable, Sendable {
    public let widgetID: String

    public init(widgetID: String) { self.widgetID = widgetID }
}

public struct ExtensionStatusSubscribeParams: Hashable, Codable, Sendable {
    public let commandID: String
    /// A fresh session per subscription; updates for older sessions are dropped.
    public let session: String

    public init(commandID: String, session: String) {
        self.commandID = commandID
        self.session = session
    }
}

public struct ExtensionStatusUnsubscribeParams: Hashable, Codable, Sendable {
    public let session: String

    public init(session: String) { self.session = session }
}

public struct ExtensionCancelParams: Hashable, Codable, Sendable {
    public let id: Int

    public init(id: Int) { self.id = id }
}

public struct ExtensionStatusUpdateParams: Hashable, Codable, Sendable {
    public let session: String
    /// `nil` restores the row's static subtitle.
    public let status: ExtensionRowStatus?

    public init(session: String, status: ExtensionRowStatus?) {
        self.session = session
        self.status = status
    }
}

/// Writes carry the request that caused them; Prism drops writes from requests
/// that already finished, timed out, or were cancelled.
public struct ExtensionStateWriteParams: Hashable, Codable, Sendable {
    public let requestID: Int
    public let key: String
    /// `nil` removes the key.
    public let value: ExtensionValue?

    public init(requestID: Int, key: String, value: ExtensionValue?) {
        self.requestID = requestID
        self.key = key
        self.value = value
    }
}

public struct ExtensionTaskStartParams: Hashable, Codable, Sendable {
    public let requestID: Int
    public let taskID: String
    public let arguments: [String]

    public init(requestID: Int, taskID: String, arguments: [String] = []) {
        self.requestID = requestID
        self.taskID = taskID
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, taskID, arguments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(Int.self, forKey: .requestID)
        taskID = try container.decode(String.self, forKey: .taskID)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
    }
}

public struct ExtensionLogParams: Hashable, Codable, Sendable {
    public let message: String

    public init(message: String) { self.message = message }
}

/// Splits stdout into lines. A line longer than `maximumLineLength` without a
/// newline is a protocol violation: the buffer is discarded and the caller
/// ends the extension.
public struct ExtensionLineBuffer: Sendable {
    public static let defaultMaximumLineLength = 4 * 1024 * 1024

    public enum Failure: Error, Equatable, Sendable {
        case lineTooLong
    }

    private var buffer = Data()
    private let maximumLineLength: Int

    public init(maximumLineLength: Int = defaultMaximumLineLength) {
        self.maximumLineLength = maximumLineLength
    }

    /// Complete lines in the appended data, without their newlines. Empty
    /// lines are skipped.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines = [Data]()
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            if line.count > maximumLineLength {
                buffer = Data()
                throw Failure.lineTooLong
            }
            if !line.isEmpty { lines.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        if buffer.count > maximumLineLength {
            buffer = Data()
            throw Failure.lineTooLong
        }
        return lines
    }
}
