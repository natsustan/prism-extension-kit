import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import Testing

/// A counter that touches every part of the protocol the test host covers.
private struct TallyExtension: PrismExtension {
    func run(command: String, context: PrismContext) async throws -> ExtensionCommandResult {
        switch command {
        case "count":
            let count = (await context.state("count")?.numberValue ?? 0) + 1
            await context.setState(.number(count), for: "count")
            await context.listChanged("history")
            await context.log("counted \(Int(count))")
            let mark = context.preferences.bool("excited") ? "!" : "."
            return .keepOpen(message: "\(Int(count))\(mark)")
        case "nap":
            await context.startTask("nap", arguments: ["5"])
            return .done
        default:
            throw PrismExtensionError("Unknown command \(command).")
        }
    }

    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        let count = Int(await context.state("count")?.numberValue ?? 0)
        return ExtensionList(items: (0..<count).map { ExtensionListItem(id: "\($0)", title: "Count \($0 + 1)") })
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        await context.setState(nil, for: "count")
        return .reload(message: "Reset")
    }

    func status(for command: String, context: PrismContext) async throws -> ExtensionRowStatus? {
        ExtensionRowStatus(text: "Counted \(Int(await context.state("count")?.numberValue ?? 0))", isLive: true)
    }

    func widget(_ widget: String, context: PrismContext) async throws -> ExtensionWidgetContent {
        .toggleCard(ExtensionToggleCard(
            title: "Counter", status: "On", symbol: "number", tint: "blue", isOn: true, toggleCommandID: "count"
        ))
    }
}

@Suite("Prism test host")
struct PrismTestHostTests {
    @Test("commands, lists, actions, status, and widgets round-trip, and the host keeps what the extension asked for")
    func roundTrips() async throws {
        let prism = try await PrismTestHost(TallyExtension(), state: ["count": .number(1)])
        #expect(try await prism.run("count") == .keepOpen(message: "2."))
        #expect(await prism.state["count"] == .number(2))
        #expect(await prism.changedLists == ["history"])
        #expect(await prism.logs == ["counted 2"])

        #expect(try await prism.list("history").items.map(\.id) == ["0", "1"])
        #expect(try await prism.status("count")?.text == "Counted 2")
        guard case let .toggleCard(card) = try await prism.widget("toggle") else {
            Issue.record("The counter's widget is a toggle card")
            return
        }
        #expect(card.title == "Counter")

        #expect(try await prism.perform("reset", on: "0", in: "history").reload)
        #expect(await prism.state["count"] == nil)

        _ = try await prism.run("nap")
        #expect(await prism.startedTasks == [PrismTestHost.TaskStart(taskID: "nap", arguments: ["5"])])
    }

    @Test("a preference change restarts the extension with the new values and the saved state")
    func preferences() async throws {
        let prism = try await PrismTestHost(TallyExtension())
        #expect(try await prism.run("count") == .keepOpen(message: "1."))
        try await prism.setPreferences(["excited": .bool(true)])
        #expect(try await prism.run("count") == .keepOpen(message: "2!"))
    }

    @Test("a restart keeps saved state and hands over the data directory")
    func restart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("prism-kit-\(UUID().uuidString)")
        let prism = try await PrismTestHost(TallyExtension(), dataDirectory: folder)
        _ = try await prism.run("count")
        try await prism.restart(with: TallyExtension())
        #expect(try await prism.run("count") == .keepOpen(message: "2."))
        #expect(await prism.dataDirectory == folder)
    }

    @Test("a failing command reports its message")
    func failure() async throws {
        let prism = try await PrismTestHost(TallyExtension())
        #expect(try await prism.run("missing") == .failed(message: "Unknown command missing."))
    }
}
