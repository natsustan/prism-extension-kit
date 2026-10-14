import Foundation
import PrismExtensionProtocol

/// What a request can see and do: the user's preferences, the extension's
/// saved state, and calls back into Prism.
public struct PrismContext: Sendable {
    public let extensionID: ExtensionID
    public let prismVersion: String
    /// Every preference the manifest declares, with defaults applied by Prism.
    public let preferences: Preferences

    let requestID: Int?
    let runtime: ExtensionRuntime

    /// A saved state value, as last written by `setState`.
    public func state(_ key: String) async -> ExtensionValue? {
        await runtime.state[key]
    }

    /// Saves a value in Prism (`state.write`). Prism keeps it across restarts
    /// and hands it back on the next start. Saved only from a command that is
    /// still running; writes from status or widget reads are ignored.
    public func setState(_ value: ExtensionValue?, for key: String) async {
        await runtime.setState(value, for: key, requestID: requestID)
    }

    /// Starts a long-running program the manifest declares under `tasks`
    /// (`task.start`). Prism launches and tracks it, and ends it when the
    /// extension is disabled or uninstalled.
    public func startTask(_ taskID: String, arguments: [String] = []) async {
        await runtime.startTask(taskID, arguments: arguments, requestID: requestID)
    }

    /// Writes a line to Prism's log for this extension.
    public func log(_ message: String) async {
        await runtime.log(message)
    }
}

/// Typed reads of the preference values Prism sent.
public struct Preferences: Sendable {
    public let values: [String: ExtensionValue]

    public init(_ values: [String: ExtensionValue]) {
        self.values = values
    }

    public subscript(_ id: String) -> ExtensionValue? { values[id] }

    public func bool(_ id: String, default fallback: Bool = false) -> Bool {
        if case let .bool(value)? = values[id] { return value }
        return fallback
    }

    public func string(_ id: String, default fallback: String = "") -> String {
        if case let .string(value)? = values[id] { return value }
        return fallback
    }

    public func number(_ id: String, default fallback: Double = 0) -> Double {
        if case let .number(value)? = values[id] { return value }
        return fallback
    }

    public func strings(_ id: String) -> [String] {
        if case let .strings(value)? = values[id] { return value }
        return []
    }
}

public extension ExtensionValue {
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }
}
