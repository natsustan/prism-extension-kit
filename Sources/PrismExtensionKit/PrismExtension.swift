@_exported import Foundation
@_exported import PrismExtensionProtocol

/// A Prism extension written in Swift. Implement the parts your
/// `manifest.json` declares and mark the type `@main`:
///
/// ```swift
/// import PrismExtensionKit
///
/// @main
/// struct Hello: PrismExtension {
///     func run(command: String, context: PrismContext) async throws -> ExtensionCommandResult {
///         .keepOpen(message: "Hello from Swift!")
///     }
/// }
/// ```
///
/// Prism starts the program on demand, talks to it over stdin and stdout,
/// and ends it when it has been idle for a while. Keep anything that must
/// survive in `context.setState`, not in properties. `print` goes to stderr,
/// where Prism keeps it for diagnostics; stdout belongs to the protocol.
public protocol PrismExtension: Sendable {
    init()

    /// `command.run`: one of the manifest's `no-view` commands.
    func run(command: String, context: PrismContext) async throws -> ExtensionCommandResult

    /// `list.load`: the items of a `list` command. Called when the scope
    /// opens, on ⌘R, after an action asks for a reload, when the ⌘P filter
    /// changes, and, for lists with `filtering: .extension`, as the user
    /// types. A newer load cancels the one before it.
    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList

    /// `detail.load`: the detail pane for an item that has no inline `detail`.
    func detail(command: String, item: String, context: PrismContext) async throws -> ExtensionDetail

    /// `action.perform`: one of an item's `perform` actions. Return
    /// `ExtensionActionResult(..., reload: true)` when the list changed.
    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult

    /// The live status for a command declared with `"liveStatus": true`.
    /// Prism asks while the row is visible, again after every command, and
    /// every `statusRefreshInterval`. `nil` keeps the row's static subtitle.
    func status(for command: String, context: PrismContext) async throws -> ExtensionRowStatus?

    /// `widget.load`: content for one of the manifest's widgets.
    func widget(_ widget: String, context: PrismContext) async throws -> ExtensionWidgetContent

    /// How often a visible live row is refreshed. `nil` refreshes it only
    /// after commands, which suits state the extension itself changes.
    var statusRefreshInterval: Duration? { get }
}

public extension PrismExtension {
    func run(command: String, context: PrismContext) async throws -> ExtensionCommandResult {
        throw PrismExtensionError("Unknown command “\(command)”.")
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        throw PrismExtensionError("Unknown list “\(command)”.")
    }

    func detail(command: String, item: String, context: PrismContext) async throws -> ExtensionDetail {
        ExtensionDetail()
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        throw PrismExtensionError("Unknown action “\(action)”.")
    }

    func status(for command: String, context: PrismContext) async throws -> ExtensionRowStatus? {
        nil
    }

    func widget(_ widget: String, context: PrismContext) async throws -> ExtensionWidgetContent {
        throw PrismExtensionError("Unknown widget “\(widget)”.")
    }

    var statusRefreshInterval: Duration? { nil }

    /// Runs the protocol loop on stdin and stdout until Prism ends it.
    static func main() async {
        await ExtensionRuntime.runStandardIO(Self())
    }
}

/// An error whose message Prism shows the user.
public struct PrismExtensionError: Error, LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public extension ExtensionCommandResult {
    /// The command finished; the launcher closes and returns focus.
    static var done: ExtensionCommandResult { .completed(message: nil, restoreFocus: true) }
}

public extension ExtensionActionResult {
    /// The action finished; the launcher closes and returns focus.
    static var done: ExtensionActionResult { ExtensionActionResult(.done) }

    /// The launcher stays on the list, which reloads; `message` is shown
    /// briefly when given.
    static func reload(message: String? = nil) -> ExtensionActionResult {
        ExtensionActionResult(message.map { .keepOpen(message: $0) } ?? .keepOpen(message: ""), reload: true)
    }
}
