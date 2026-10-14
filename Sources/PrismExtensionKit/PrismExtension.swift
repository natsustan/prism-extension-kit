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
