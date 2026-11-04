import Foundation
import PrismExtensionProtocol

/// What a request can see and do: the user's preferences, the extension's
/// saved state, and calls back into Prism.
public struct PrismContext: Sendable {
    public let extensionID: ExtensionID
    public let prismVersion: String
    /// Every preference the manifest declares, with defaults applied by Prism.
    public let preferences: Preferences
    /// A folder this extension owns, for caches that should outlive the
    /// process. Prism creates it and deletes it on uninstall; `nil` under a
    /// Prism that predates it.
    public let dataDirectory: URL?
    /// Prism's interface language (`en`, `zh-Hans`, `zh-Hant`), or nil under
    /// a Prism that predates it. Look strings up with
    /// `.module.prismLocalized`; see `PrismLocalization`.
    public let language: String?

    let requestID: Int?
    let runtime: ExtensionRuntime

    /// Prism's language with the user's region, for formatting numbers and
    /// dates next to translated text.
    public var locale: Locale { PrismLocalization.locale(for: language) }

    /// A saved state value, as last written by `setState`.
    public func state(_ key: String) async -> ExtensionValue? {
        await runtime.state[key]
    }

    /// Saves a value in Prism (`state.write`). Prism keeps it across restarts
    /// and hands it back on the next start. Saved only from a request that is
    /// still running (a command, list, action, or widget load); writes from
    /// status reads, or after the request ended, are ignored, and so is a
    /// write that would take the extension's state past 1 MB.
    public func setState(_ value: ExtensionValue?, for key: String) async {
        await runtime.setState(value, for: key, requestID: requestID)
    }

    /// Starts a long-running program the manifest declares under `tasks`
    /// (`task.start`). Prism launches and tracks it, and ends it when the
    /// extension is disabled or uninstalled.
    public func startTask(_ taskID: String, arguments: [String] = []) async {
        await runtime.startTask(taskID, arguments: arguments, requestID: requestID)
    }

    /// Tells Prism that a list command's data changed (`list.changed`), for
    /// example when a refresh started by an earlier load finishes. Prism
    /// reloads the list if it is on screen.
    public func listChanged(_ command: String) async {
        await runtime.listChanged(command)
    }

    /// Tells Prism that widgets' data changed (`widget.changed`): the
    /// widgets named, or every widget of the extension when `widgets` is
    /// nil. Prism reloads the ones on screen. Set
    /// `PrismExtension.notifiesWidgetChanges` so Prism stops polling them
    /// every few seconds.
    public func widgetChanged(_ widgets: [String]? = nil) async {
        await runtime.widgetChanged(widgets)
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

    /// An `orderedList` preference: the user's order and switches. Resolve
    /// it against your items with `enabledIDs(with:)`.
    public func orderedList(_ id: String) -> ExtensionOrderedList {
        ExtensionOrderedList(value: values[id])
    }
}
