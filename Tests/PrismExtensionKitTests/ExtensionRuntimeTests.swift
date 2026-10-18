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
        case "stubborn":
            // Ignores cancellation, then writes anyway.
            try? await Task.sleep(for: .seconds(30))
            await context.setState(.string("late"), for: "mark")
            return .done
        case "hang":
            // Ignores cancellation and never checks it.
            await Task.detached { try? await Task.sleep(for: .seconds(30)) }.value
            return .done
        case "hoard":
            // Past the state quota: Prism would refuse it.
            await context.setState(.string(String(repeating: "a", count: ExtensionStateQuota.limit)), for: "mark")
            return .done
        case "mark":
            return .keepOpen(message: await context.state("mark")?.stringValue ?? "unset")
        default:
            throw PrismExtensionError("No such command.")
        }
    }

    func status(for command: String, context: PrismContext) async throws -> ExtensionRowStatus? {
        // Ignored: status reads cannot save state.
        await context.setState(.string("status"), for: "mark")
        let count = Int(await context.state("count")?.numberValue ?? 0)
        return ExtensionRowStatus(text: "Count \(count)", isLive: true)
    }

    func widget(_ widget: String, context: PrismContext) async throws -> ExtensionWidgetContent {
        .toggleCard(ExtensionToggleCard(
            title: "Counter", status: "On", symbol: "number", tint: "blue", isOn: true, toggleCommandID: "increment"
        ))
    }
}

/// Holds status reads until the test releases them, ignoring cancellation
/// the way an extension that never checks it would.
final class StatusGate: Sendable {
    private let held = Mutex<[CheckedContinuation<Void, Never>]>([])

    var waiting: Int { held.withLock { $0.count } }

    func wait() async {
        await withCheckedContinuation { continuation in
            held.withLock { $0.append(continuation) }
        }
    }

    func release() {
        for continuation in held.withLock({ held in defer { held.removeAll() }; return held }) {
            continuation.resume()
        }
    }
}

let statusGate = StatusGate()

/// Shows its `label` preference as the status, held at the gate while `hold` is on.
struct Labeler: PrismExtension {
    func status(for command: String, context: PrismContext) async throws -> ExtensionRowStatus? {
        if context.preferences.bool("hold") { await statusGate.wait() }
        return ExtensionRowStatus(text: context.preferences.string("label"), isLive: true)
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
        #expect(try recorder.response(1)?.result?.decode(ExtensionInitializeResult.self).updatesPreferences == true)

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

    @Test("preferences.update reaches the next request without a restart")
    func preferencesUpdate() async throws {
        let (runtime, recorder) = await initialized(#"{"quiet":true}"#)
        await send(runtime, #"{"method":"preferences.update","params":{"preferences":{"quiet":false}}}"#)
        await send(runtime, #"{"id":2,"method":"command.run","params":{"commandID":"increment"}}"#)
        await settle(runtime)
        #expect(try recorder.response(2)?.result?.decode(ExtensionCommandResult.self) == .keepOpen(message: "Count: 1"))
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

        // The status reads' writes were neither sent nor kept.
        let keys = try recorder.notifications("state.write").map { try #require($0.params).decode(ExtensionStateWriteParams.self).key }
        #expect(!keys.contains("mark"))
        await send(runtime, #"{"id":5,"method":"command.run","params":{"commandID":"mark"}}"#)
        await settle(runtime)
        #expect(try recorder.response(5)?.result?.decode(ExtensionCommandResult.self) == .keepOpen(message: "unset"))
    }

    @Test("a status read that returns after a newer one is not published")
    func staleStatus() async throws {
        let recorder = OutputRecorder()
        let runtime = ExtensionRuntime(Labeler(), output: { recorder.record($0) }, exit: {})
        await send(runtime, #"{"id":1,"method":"initialize","params":{"protocol":1,"prismVersion":"1.0","extensionID":"octocat.labeler","preferences":{"label":"old","hold":true},"state":{}}}"#)
        func statuses() throws -> [String?] {
            try recorder.notifications("status.update").map {
                try #require($0.params).decode(ExtensionStatusUpdateParams.self).status?.text
            }
        }
        func eventually(_ condition: () throws -> Bool) async rethrows {
            let deadline = ContinuousClock.now + .seconds(5)
            while try !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        // The first read holds the old preferences.
        await send(runtime, #"{"id":2,"method":"status.subscribe","params":{"commandID":"status","session":"s1"}}"#)
        await eventually { statusGate.waiting == 1 }
        #expect(statusGate.waiting == 1)

        // A newer read with the new preferences finishes first.
        await send(runtime, #"{"method":"preferences.update","params":{"preferences":{"label":"new"}}}"#)
        try await eventually { try statuses() == ["new"] }
        #expect(try statuses() == ["new"])

        // The old read returns last and is dropped.
        statusGate.release()
        await settle(runtime)
        #expect(try statuses() == ["new"])
    }

    @Test("when Prism's pipe closes, requests are canceled and the runtime exits within a grace period")
    func hostClosed() async throws {
        let exits = Mutex(0)
        let runtime = ExtensionRuntime(Counter(), output: { _ in }, exit: { exits.withLock { $0 += 1 } })
        await send(runtime, #"{"id":1,"method":"initialize","params":{"protocol":1,"prismVersion":"1.0","extensionID":"octocat.counter","preferences":{},"state":{}}}"#)

        // A request that honors cancellation ends at once; no need to wait out the grace.
        await send(runtime, #"{"id":2,"method":"command.run","params":{"commandID":"slow"}}"#)
        var start = ContinuousClock.now
        await runtime.hostClosed(grace: .seconds(10))
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(exits.withLock { $0 } == 1)

        // One that ignores it is abandoned when the grace ends.
        await send(runtime, #"{"id":3,"method":"command.run","params":{"commandID":"hang"}}"#)
        start = ContinuousClock.now
        await runtime.hostClosed(grace: .milliseconds(200))
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(exits.withLock { $0 } == 2)
    }

    @Test("a canceled request's later state write changes nothing")
    func canceledStateWrite() async throws {
        let (runtime, recorder) = await initialized()
        await send(runtime, #"{"id":2,"method":"command.run","params":{"commandID":"stubborn"}}"#)
        await send(runtime, #"{"method":"cancel","params":{"id":2}}"#)
        await settle(runtime)
        #expect(recorder.notifications("state.write").isEmpty)

        await send(runtime, #"{"id":3,"method":"command.run","params":{"commandID":"mark"}}"#)
        await settle(runtime)
        #expect(try recorder.response(3)?.result?.decode(ExtensionCommandResult.self) == .keepOpen(message: "unset"))
    }

    @Test("a write past the state quota is not sent and leaves the local state unchanged")
    func stateQuota() async throws {
        let (runtime, recorder) = await initialized()
        await send(runtime, #"{"id":2,"method":"command.run","params":{"commandID":"hoard"}}"#)
        await settle(runtime)
        #expect(recorder.notifications("state.write").isEmpty)
        let log = try #require(recorder.notifications("log").first?.params).decode(ExtensionLogParams.self)
        #expect(log.message.hasPrefix(#"Ignored state "mark""#))

        await send(runtime, #"{"id":3,"method":"command.run","params":{"commandID":"mark"}}"#)
        await settle(runtime)
        #expect(try recorder.response(3)?.result?.decode(ExtensionCommandResult.self) == .keepOpen(message: "unset"))
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
