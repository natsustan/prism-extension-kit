import Foundation
import PrismExtensionKit
import PrismExtensionProtocol

/// Prism, played in memory, for an extension's own tests. It drives the
/// extension through the same runtime and protocol messages Prism uses, and
/// keeps what the extension asked of Prism: saved state, started tasks,
/// changed lists, and log lines.
///
///     let prism = await PrismTestHost(MyExtension(), preferences: ["excited": .bool(true)])
///     #expect(try await prism.run("greet") == .keepOpen(message: "Hello!"))
///     #expect(await prism.state["greetings"] == .number(1))
public actor PrismTestHost {
    public struct TaskStart: Hashable, Sendable {
        public let taskID: String
        public let arguments: [String]

        public init(taskID: String, arguments: [String] = []) {
            self.taskID = taskID
            self.arguments = arguments
        }
    }

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public let extensionID: ExtensionID
    /// The folder handed over as the extension's data directory.
    public let dataDirectory: URL?
    /// Preferences as `initialize` or the last `preferences.update` sent them.
    public private(set) var preferences: [String: ExtensionValue]
    /// What Prism would keep for the extension (`state.write`).
    public private(set) var state: [String: ExtensionValue]
    /// `task.start` requests, in order.
    public private(set) var startedTasks: [TaskStart] = []
    /// `list.changed` notifications, in order.
    public private(set) var changedLists: [String] = []
    /// `log` messages, in order.
    public private(set) var logs: [String] = []

    private var extensionValue: any PrismExtension
    private var runtime: ExtensionRuntime
    private var lines: LineSource
    private var responses: [Int: ExtensionMessage] = [:]
    private var statuses: [String: ExtensionRowStatus?] = [:]
    private var nextID = 1
    private var nextSession = 1

    public init(
        _ extensionValue: any PrismExtension,
        extensionID: ExtensionID = "octocat.test",
        preferences: [String: ExtensionValue] = [:],
        state: [String: ExtensionValue] = [:],
        dataDirectory: URL? = nil
    ) async throws {
        self.extensionValue = extensionValue
        self.extensionID = extensionID
        self.dataDirectory = dataDirectory
        self.preferences = preferences
        self.state = state
        (runtime, lines) = Self.makeRuntime(extensionValue)
        try await initialize()
    }

    private static func makeRuntime(_ extensionValue: any PrismExtension) -> (ExtensionRuntime, LineSource) {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let runtime = ExtensionRuntime(
            extensionValue,
            output: { continuation.yield($0) },
            exit: { continuation.finish() }
        )
        return (runtime, LineSource(stream))
    }

    /// Prism hands a running extension new preferences in place
    /// (`preferences.update`); the next call sees them.
    public func setPreferences(_ preferences: [String: ExtensionValue]) async throws {
        self.preferences = preferences
        try await notify(ExtensionMethod.preferencesUpdate, ExtensionPreferencesUpdateParams(preferences: preferences))
    }

    /// Prism stops an idle extension and starts it again on the next
    /// request. Pass a fresh instance to drop everything the old process held
    /// in memory; saved state and the data directory carry over.
    public func restart(with extensionValue: (any PrismExtension)? = nil) async throws {
        await runtime.finish()
        if let extensionValue { self.extensionValue = extensionValue }
        (runtime, lines) = Self.makeRuntime(self.extensionValue)
        try await initialize()
    }

    private func initialize() async throws {
        _ = try await request(ExtensionMethod.initialize, ExtensionInitializeParams(
            prismVersion: "test", extensionID: extensionID, preferences: preferences, state: state,
            dataDirectory: dataDirectory?.path
        ))
    }

    // MARK: - Calls

    /// `command.run`.
    public func run(_ command: String) async throws -> ExtensionCommandResult {
        try await request(ExtensionMethod.commandRun, ExtensionCommandParams(commandID: command))
            .decode(ExtensionCommandResult.self)
    }

    /// `list.load`.
    public func list(_ command: String, query: String = "", filter: String? = nil) async throws -> ExtensionList {
        try await request(ExtensionMethod.listLoad, ExtensionListParams(commandID: command, query: query, filter: filter))
            .decode(ExtensionList.self)
    }

    /// `detail.load`.
    public func detail(_ item: String, in command: String) async throws -> ExtensionDetail {
        try await request(ExtensionMethod.detailLoad, ExtensionDetailParams(commandID: command, itemID: item))
            .decode(ExtensionDetail.self)
    }

    /// `action.perform`.
    public func perform(_ action: String, on item: String, in command: String) async throws -> ExtensionActionResult {
        try await request(
            ExtensionMethod.actionPerform,
            ExtensionActionParams(commandID: command, itemID: item, actionID: action)
        )
        .decode(ExtensionActionResult.self)
    }

    /// `preferences.items` for an `orderedList` preference.
    public func preferenceItems(_ preference: String) async throws -> [ExtensionPreferenceItem] {
        try await request(ExtensionMethod.preferencesItems, ExtensionPreferenceItemsParams(preferenceID: preference))
            .decode(ExtensionPreferenceItems.self).items
    }

    /// `widget.load`.
    public func widget(_ widget: String) async throws -> ExtensionWidgetContent {
        try await request(ExtensionMethod.widgetLoad, ExtensionWidgetParams(widgetID: widget))
            .decode(ExtensionWidgetContent.self)
    }

    /// The live status a row of `command` shows right now: subscribes, takes
    /// the first `status.update`, and unsubscribes.
    public func status(_ command: String) async throws -> ExtensionRowStatus? {
        let session = "test-\(nextSession)"
        nextSession += 1
        _ = try await request(
            ExtensionMethod.statusSubscribe, ExtensionStatusSubscribeParams(commandID: command, session: session)
        )
        while statuses[session] == nil {
            try await readLine()
        }
        try await notify(ExtensionMethod.statusUnsubscribe, ExtensionStatusUnsubscribeParams(session: session))
        return statuses.removeValue(forKey: session) ?? nil
    }

    // MARK: - Wire

    private func request<Params: Encodable>(_ method: String, _ params: Params) async throws -> ExtensionJSON {
        let id = nextID
        nextID += 1
        await runtime.receive(try ExtensionMessage.request(id: id, method: method, params: params).line())
        while responses[id] == nil {
            try await readLine()
        }
        let response = responses.removeValue(forKey: id)!
        if let error = response.error {
            throw Failure(description: error.message)
        }
        return response.result ?? .null
    }

    private func notify<Params: Encodable>(_ method: String, _ params: Params) async throws {
        await runtime.receive(try ExtensionMessage.notification(method: method, params: params).line())
    }

    private func readLine() async throws {
        guard let line = await lines.next() else {
            throw Failure(description: "The extension stopped.")
        }
        let message = try ExtensionWire.decode(ExtensionMessage.self, from: line)
        switch message.kind {
        case let .response(id):
            responses[id] = message
        case let .notification(method):
            let params = message.params ?? .null
            switch method {
            case ExtensionMethod.stateWrite:
                let write = try params.decode(ExtensionStateWriteParams.self)
                state[write.key] = write.value
            case ExtensionMethod.taskStart:
                let start = try params.decode(ExtensionTaskStartParams.self)
                startedTasks.append(TaskStart(taskID: start.taskID, arguments: start.arguments))
            case ExtensionMethod.listChanged:
                changedLists.append(try params.decode(ExtensionListChangedParams.self).commandID)
            case ExtensionMethod.log:
                logs.append(try params.decode(ExtensionLogParams.self).message)
            case ExtensionMethod.statusUpdate:
                let update = try params.decode(ExtensionStatusUpdateParams.self)
                statuses[update.session] = .some(update.status)
            default:
                break
            }
        case .request, .invalid:
            break
        }
    }
}

/// The extension's output lines. Only the host actor reads them, one call at
/// a time; the class lets it advance the iterator across suspension points.
private final class LineSource: @unchecked Sendable {
    private var iterator: AsyncStream<Data>.Iterator

    init(_ stream: AsyncStream<Data>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async -> Data? {
        await iterator.next()
    }
}
