import Darwin
import Foundation
import PrismExtensionProtocol

/// The protocol loop behind `PrismExtension.main()`: decodes each line from
/// Prism, calls the extension, and writes replies and notifications. Requests
/// run concurrently; output is serialized by the actor.
public actor ExtensionRuntime {
    private let extensionValue: any PrismExtension
    private let output: @Sendable (Data) -> Void
    private let exit: @Sendable () -> Void

    private(set) var state: [String: ExtensionValue] = [:]
    private var stateQuota = ExtensionStateQuota()
    private var extensionID: ExtensionID = ""
    private var prismVersion = ""
    private var preferences = Preferences([:])
    private var dataDirectory: URL?
    private var requests: [Int: Task<Void, Never>] = [:]
    /// Requests Prism canceled. They may still be running, but Prism no
    /// longer accepts their writes.
    private var canceledRequests: Set<Int> = []
    /// Live status sessions: session → command, with an optional refresh loop.
    private var sessions: [String: String] = [:]
    private var refreshers: [String: Task<Void, Never>] = [:]

    /// `output` receives complete lines, newline included. `exit` ends the
    /// program when Prism asks it to stop.
    public init(
        _ extensionValue: any PrismExtension,
        output: @escaping @Sendable (Data) -> Void,
        exit: @escaping @Sendable () -> Void = { Darwin.exit(0) }
    ) {
        self.extensionValue = extensionValue
        self.output = output
        self.exit = exit
    }

    /// Runs on the real stdin and stdout. stdout is taken over for the
    /// protocol and `print` is redirected to stderr, so stray output cannot
    /// corrupt a message.
    static func runStandardIO(_ extensionValue: any PrismExtension) async {
        let protocolDescriptor = dup(STDOUT_FILENO)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let protocolOutput = FileHandle(fileDescriptor: protocolDescriptor, closeOnDealloc: true)
        let runtime = ExtensionRuntime(extensionValue, output: { protocolOutput.write($0) })
        // Framed like Prism frames them: at "\n" only. `bytes.lines` would
        // also break at CR, U+2028, and U+2029, which JSON strings may hold.
        let chunks = AsyncStream<Data> { continuation in
            FileHandle.standardInput.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
        var buffer = ExtensionLineBuffer()
        do {
            for await chunk in chunks {
                for line in try buffer.append(chunk) { await runtime.receive(line) }
            }
        } catch {
            FileHandle.standardError.write(Data("Reading from Prism failed: \(error)\n".utf8))
        }
        await runtime.hostClosed()
        Darwin.exit(0)
    }

    /// Handles one line from Prism.
    public func receive(_ line: Data) {
        guard let message = try? ExtensionWire.decode(ExtensionMessage.self, from: line) else {
            log("Ignored a line that is not a protocol message.")
            return
        }
        switch message.kind {
        case let .request(id, method):
            handleRequest(id: id, method: method, params: message.params ?? .null)
        case let .notification(method):
            handleNotification(method, params: message.params ?? .null)
        case .response, .invalid:
            break
        }
    }

    /// Waits until every request received so far has replied.
    public func waitForRequests() async {
        while let task = requests.values.first {
            await task.value
        }
    }

    /// Prism closed the pipe without `willTerminate`: it crashed or was
    /// killed, so nothing remains to time requests out or end this process.
    /// Cancels every request and refresh loop, gives them `grace` to unwind,
    /// then exits, even if a request ignores cancellation.
    public func hostClosed(grace: Duration = .seconds(1)) async {
        for (id, request) in requests {
            canceledRequests.insert(id)
            request.cancel()
        }
        for refresher in refreshers.values { refresher.cancel() }
        refreshers.removeAll()
        let deadline = ContinuousClock.now + grace
        while !requests.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        exit()
    }

    /// Waits for running requests, then stops every refresh loop.
    public func finish() async {
        await waitForRequests()
        for refresher in refreshers.values { refresher.cancel() }
        refreshers.removeAll()
    }

    // MARK: - Requests

    private func handleRequest(id: Int, method: String, params: ExtensionJSON) {
        switch method {
        case ExtensionMethod.initialize:
            do {
                let initialize = try params.decode(ExtensionInitializeParams.self)
                extensionID = initialize.extensionID
                prismVersion = initialize.prismVersion
                preferences = Preferences(initialize.preferences)
                state = initialize.state
                stateQuota = ExtensionStateQuota(initialize.state)
                dataDirectory = initialize.dataDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
                reply(id, result: .object([:]))
            } catch {
                reply(id, error: "Invalid initialize parameters.")
            }
        case ExtensionMethod.commandRun:
            guard let command = try? params.decode(ExtensionCommandParams.self) else {
                return reply(id, error: "Invalid command.run parameters.")
            }
            start(id) { runtime, context in
                let result: ExtensionCommandResult
                do {
                    result = try await runtime.extensionValue.run(command: command.commandID, context: context)
                } catch {
                    result = .failed(message: Self.message(for: error))
                }
                await runtime.reply(id, encoding: result)
                // Commands usually change what a live row shows.
                await runtime.refreshAllStatuses()
            }
        case ExtensionMethod.listLoad:
            guard let list = try? params.decode(ExtensionListParams.self) else {
                return reply(id, error: "Invalid list.load parameters.")
            }
            start(id) { runtime, context in
                do {
                    let result = try await runtime.extensionValue.list(
                        command: list.commandID, query: list.query, filter: list.filter, context: context
                    )
                    await runtime.reply(id, encoding: result)
                } catch {
                    await runtime.reply(id, error: Self.message(for: error))
                }
            }
        case ExtensionMethod.detailLoad:
            guard let detail = try? params.decode(ExtensionDetailParams.self) else {
                return reply(id, error: "Invalid detail.load parameters.")
            }
            start(id) { runtime, context in
                do {
                    let result = try await runtime.extensionValue.detail(
                        command: detail.commandID, item: detail.itemID, context: context
                    )
                    await runtime.reply(id, encoding: result)
                } catch {
                    await runtime.reply(id, error: Self.message(for: error))
                }
            }
        case ExtensionMethod.actionPerform:
            guard let action = try? params.decode(ExtensionActionParams.self) else {
                return reply(id, error: "Invalid action.perform parameters.")
            }
            start(id) { runtime, context in
                let result: ExtensionActionResult
                do {
                    result = try await runtime.extensionValue.perform(
                        action: action.actionID, item: action.itemID, command: action.commandID, context: context
                    )
                } catch {
                    result = ExtensionActionResult(.failed(message: Self.message(for: error)))
                }
                await runtime.reply(id, encoding: result)
                await runtime.refreshAllStatuses()
            }
        case ExtensionMethod.preferencesItems:
            guard let request = try? params.decode(ExtensionPreferenceItemsParams.self) else {
                return reply(id, error: "Invalid preferences.items parameters.")
            }
            start(id) { runtime, context in
                do {
                    let items = try await runtime.extensionValue.preferenceItems(request.preferenceID, context: context)
                    await runtime.reply(id, encoding: ExtensionPreferenceItems(items: items))
                } catch {
                    await runtime.reply(id, error: Self.message(for: error))
                }
            }
        case ExtensionMethod.widgetLoad:
            guard let widget = try? params.decode(ExtensionWidgetParams.self) else {
                return reply(id, error: "Invalid widget.load parameters.")
            }
            start(id) { runtime, context in
                do {
                    let content = try await runtime.extensionValue.widget(widget.widgetID, context: context)
                    await runtime.reply(id, encoding: content)
                } catch {
                    await runtime.reply(id, error: Self.message(for: error))
                }
            }
        case ExtensionMethod.statusSubscribe:
            guard let subscribe = try? params.decode(ExtensionStatusSubscribeParams.self) else {
                return reply(id, error: "Invalid status.subscribe parameters.")
            }
            sessions[subscribe.session] = subscribe.commandID
            start(id) { runtime, _ in
                await runtime.reply(id, result: .object([:]))
                await runtime.refreshStatus(subscribe.session)
                await runtime.startRefreshing(subscribe.session)
            }
        default:
            reply(id, error: "Unsupported method \(method).")
        }
    }

    private func handleNotification(_ method: String, params: ExtensionJSON) {
        switch method {
        case ExtensionMethod.statusUnsubscribe:
            guard let unsubscribe = try? params.decode(ExtensionStatusUnsubscribeParams.self) else { return }
            sessions[unsubscribe.session] = nil
            refreshers.removeValue(forKey: unsubscribe.session)?.cancel()
        case ExtensionMethod.cancel:
            guard let cancel = try? params.decode(ExtensionCancelParams.self) else { return }
            guard let request = requests[cancel.id] else { return }
            canceledRequests.insert(cancel.id)
            request.cancel()
        case ExtensionMethod.willTerminate:
            exit()
        default:
            break
        }
    }

    private func start(
        _ id: Int,
        _ work: @escaping @Sendable (ExtensionRuntime, PrismContext) async -> Void
    ) {
        let context = makeContext(requestID: id)
        requests[id] = Task {
            await work(self, context)
            self.requestFinished(id)
        }
    }

    private func requestFinished(_ id: Int) {
        requests[id] = nil
        canceledRequests.remove(id)
    }

    private func makeContext(requestID: Int?) -> PrismContext {
        PrismContext(
            extensionID: extensionID, prismVersion: prismVersion, preferences: preferences,
            dataDirectory: dataDirectory, requestID: requestID, runtime: self
        )
    }

    // MARK: - Live status

    private func startRefreshing(_ session: String) {
        guard sessions[session] != nil, let interval = extensionValue.statusRefreshInterval else { return }
        refreshers[session] = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self.refreshStatus(session)
            }
        }
    }

    private func refreshAllStatuses() async {
        for session in sessions.keys {
            await refreshStatus(session)
        }
    }

    private func refreshStatus(_ session: String) async {
        guard let command = sessions[session] else { return }
        let status: ExtensionRowStatus?
        do {
            status = try await extensionValue.status(for: command, context: makeContext(requestID: nil))
        } catch {
            status = ExtensionRowStatus(
                text: "Error", symbol: "exclamationmark.triangle.fill", tone: .critical,
                isLive: true, help: Self.message(for: error)
            )
        }
        // The row may have left the screen while the status was computed.
        guard sessions[session] != nil else { return }
        notify(ExtensionMethod.statusUpdate, ExtensionStatusUpdateParams(session: session, status: status))
    }

    // MARK: - Calls into Prism

    func setState(_ value: ExtensionValue?, for key: String, requestID: Int?) {
        // Prism saves writes only from a request still in flight, so the copy
        // here must not keep any other: one from a status read, or from a
        // request that ended or was canceled.
        guard let requestID else {
            log("Ignored a state write made outside a request.")
            return
        }
        guard requests[requestID] != nil, !canceledRequests.contains(requestID) else {
            log("Ignored a state write from request \(requestID), which already ended.")
            return
        }
        // Prism would refuse it; keeping it here would show a value that is
        // gone after a restart.
        guard stateQuota.admit(value, for: key) else {
            log("Ignored state \"\(key)\": an extension keeps at most \(ExtensionStateQuota.limit / 1024) KB of state.")
            return
        }
        state[key] = value
        notify(ExtensionMethod.stateWrite, ExtensionStateWriteParams(requestID: requestID, key: key, value: value))
    }

    func startTask(_ taskID: String, arguments: [String], requestID: Int?) {
        guard let requestID else {
            log("Task \(taskID) can only start from a command.")
            return
        }
        notify(ExtensionMethod.taskStart, ExtensionTaskStartParams(requestID: requestID, taskID: taskID, arguments: arguments))
    }

    func listChanged(_ commandID: String) {
        notify(ExtensionMethod.listChanged, ExtensionListChangedParams(commandID: commandID))
    }

    func log(_ message: String) {
        notify(ExtensionMethod.log, ExtensionLogParams(message: message))
    }

    // MARK: - Output

    private func reply<Value: Encodable>(_ id: Int, encoding value: Value) {
        do {
            reply(id, result: try ExtensionJSON(encoding: value))
        } catch {
            reply(id, error: "The extension produced a result Prism cannot read.")
        }
    }

    private func reply(_ id: Int, result: ExtensionJSON) {
        write(ExtensionMessage(id: id, result: result))
    }

    private func reply(_ id: Int, error message: String) {
        write(ExtensionMessage(id: id, error: ExtensionRPCError(message: message)))
    }

    private func notify<Params: Encodable>(_ method: String, _ params: Params) {
        guard let message = try? ExtensionMessage.notification(method: method, params: params) else { return }
        write(message)
    }

    private func write(_ message: ExtensionMessage) {
        guard let line = try? message.line() else { return }
        output(line)
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
