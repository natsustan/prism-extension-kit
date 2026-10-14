import Foundation
import PrismExtensionKit
import Synchronization
import Testing

/// Collects what the runtime writes, one decoded message per line.
final class OutputRecorder: Sendable {
    private let lines = Mutex<[ExtensionMessage]>([])

    var messages: [ExtensionMessage] { lines.withLock { $0 } }

    func record(_ data: Data) {
        guard let message = try? ExtensionWire.decode(ExtensionMessage.self, from: data.dropLast()) else { return }
        lines.withLock { $0.append(message) }
    }

    func response(_ id: Int) -> ExtensionMessage? {
        messages.first { $0.kind == .response(id: id) }
    }

    func notifications(_ method: String) -> [ExtensionMessage] {
        messages.filter { $0.kind == .notification(method: method) }
    }
}

struct Counter: PrismExtension {
    func run(command: String, context: PrismContext) async throws -> ExtensionCommandResult {
        switch command {
        case "increment":
            let count = (await context.state("count")?.numberValue ?? 0) + 1
            await context.setState(.number(count), for: "count")
            if context.preferences.bool("quiet") { return .done }
            return .keepOpen(message: "Count: \(Int(count))")
        case "nap":
            await context.startTask("nap", arguments: ["1"])
            return .done
        case "slow":
            try await Task.sleep(for: .seconds(30))
            return .done
        default:
            throw PrismExtensionError("No such command.")
        }
    }

    func status(for command: String, context: PrismContext) async throws -> ExtensionRowStatus? {
        let count = Int(await context.state("count")?.numberValue ?? 0)
        return ExtensionRowStatus(text: "Count \(count)", isLive: true)
    }

    func widget(_ widget: String, context: PrismContext) async throws -> ExtensionWidgetContent {
        .toggleCard(ExtensionToggleCard(
            title: "Counter", status: "On", symbol: "number", tint: "blue", isOn: true, toggleCommandID: "increment"
        ))
    }
}

@Suite("Extension runtime")
struct ExtensionRuntimeTests {
    private func send(_ runtime: ExtensionRuntime, _ json: String) async {
        await runtime.receive(Data(json.utf8))
    }

    private func settle(_ runtime: ExtensionRuntime) async {
        await runtime.waitForRequests()
    }

    private func initialized(_ preferences: String = "{}", state: String = "{}") async -> (ExtensionRuntime, OutputRecorder) {
        let recorder = OutputRecorder()
        let runtime = ExtensionRuntime(Counter(), output: { recorder.record($0) }, exit: {})
        await send(runtime, #"{"id":1,"method":"initialize","params":{"protocol":1,"prismVersion":"1.0","extensionID":"octocat.counter","preferences":\#(preferences),"state":\#(state)}}"#)
        return (runtime, recorder)
    }

    @Test("commands run with preferences and state, and write state for the request")
    func commands() async throws {
        let (runtime, recorder) = await initialized(state: #"{"count":2}"#)
        #expect(recorder.response(1)?.result == .object([:]))

        await send(runtime, #"{"id":2,"method":"command.run","params":{"commandID":"increment"}}"#)
        await settle(runtime)
        let result = try #require(recorder.response(2)?.result).decode(ExtensionCommandResult.self)
        #expect(result == .keepOpen(message: "Count: 3"))
        let write = try #require(recorder.notifications("state.write").first?.params).decode(ExtensionStateWriteParams.self)
        #expect(write == ExtensionStateWriteParams(requestID: 2, key: "count", value: .number(3)))

        await send(runtime, #"{"id":3,"method":"command.run","params":{"commandID":"missing"}}"#)
        await settle(runtime)
        #expect(try recorder.response(3)?.result?.decode(ExtensionCommandResult.self) == .failed(message: "No such command."))
    }

    @Test("preferences from initialize change command behavior")
    func preferences() async throws {
        let (runtime, recorder) = await initialized(#"{"quiet":true}"#)
        await send(runtime, #"{"id":2,"method":"command.run","params":{"commandID":"increment"}}"#)
        await settle(runtime)
        #expect(try recorder.response(2)?.result?.decode(ExtensionCommandResult.self) == .done)
    }

    @Test("live status pushes on subscribe and after commands, and stops on unsubscribe")
    func liveStatus() async throws {
        let (runtime, recorder) = await initialized()
        await send(runtime, #"{"id":2,"method":"status.subscribe","params":{"commandID":"status","session":"s1"}}"#)
        await settle(runtime)
        #expect(recorder.response(2)?.result == .object([:]))
        func statuses() throws -> [String?] {
            try recorder.notifications("status.update").map {
                try #require($0.params).decode(ExtensionStatusUpdateParams.self).status?.text
            }
        }
        #expect(try statuses() == ["Count 0"])

        await send(runtime, #"{"id":3,"method":"command.run","params":{"commandID":"increment"}}"#)
        await settle(runtime)
        #expect(try statuses() == ["Count 0", "Count 1"])

        await send(runtime, #"{"method":"status.unsubscribe","params":{"session":"s1"}}"#)
        await send(runtime, #"{"id":4,"method":"command.run","params":{"commandID":"increment"}}"#)
        await settle(runtime)
        #expect(try statuses() == ["Count 0", "Count 1"])
    }

    @Test("widgets, task starts, cancellation, and unknown methods")
    func otherMessages() async throws {
        let (runtime, recorder) = await initialized()
        await send(runtime, #"{"id":2,"method":"widget.load","params":{"widgetID":"card"}}"#)
        await send(runtime, #"{"id":3,"method":"command.run","params":{"commandID":"nap"}}"#)
        await send(runtime, #"{"id":4,"method":"command.run","params":{"commandID":"slow"}}"#)
        await send(runtime, #"{"method":"cancel","params":{"id":4}}"#)
        await send(runtime, #"{"id":5,"method":"background.refresh","params":{}}"#)
        await send(runtime, "not json")
        await settle(runtime)

        guard case let .toggleCard(card)? = try recorder.response(2)?.result?.decode(ExtensionWidgetContent.self) else {
            Issue.record("Expected a toggle card")
            return
        }
        #expect(card.title == "Counter")
        let task = try #require(recorder.notifications("task.start").first?.params).decode(ExtensionTaskStartParams.self)
        #expect(task == ExtensionTaskStartParams(requestID: 3, taskID: "nap", arguments: ["1"]))
        guard case let .failed(message)? = try recorder.response(4)?.result?.decode(ExtensionCommandResult.self) else {
            Issue.record("Expected the cancelled command to fail")
            return
        }
        #expect(!message.isEmpty)
        #expect(recorder.response(5)?.error?.message == "Unsupported method background.refresh.")
        #expect(!recorder.notifications("log").isEmpty)
    }
}
