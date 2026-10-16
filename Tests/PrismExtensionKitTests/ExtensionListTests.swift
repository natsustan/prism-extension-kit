import Foundation
import PrismExtensionKit
import Testing

/// A to-do list kept in state: items carry inline detail for the first
/// entry only, so the rest come from `detail.load`.
struct Todos: PrismExtension {
    func list(command: String, query: String, filter: String?, context: PrismContext) async throws -> ExtensionList {
        guard command == "todos" else { throw PrismExtensionError("No such list.") }
        let titles = await context.state("todos").flatMap {
            if case let .strings(values) = $0 { values } else { nil }
        } ?? ["Buy milk", "Walk"]
        let items = titles.enumerated()
            .filter { query.isEmpty || $0.element.localizedCaseInsensitiveContains(query) }
            .map { index, title in
                ExtensionListItem(
                    id: title, title: title,
                    detail: index == 0 ? ExtensionDetail(markdown: "**\(title)**") : nil,
                    actions: [
                        ExtensionAction(id: "done", title: "Mark Done", symbol: "checkmark", style: .destructive),
                        ExtensionAction(id: "copy", title: "Copy", kind: .copy(text: title), shortcut: ExtensionShortcut("cmd+shift+c")),
                    ]
                )
            }
        return ExtensionList(items: items, filtering: .extension, filters: [ExtensionListFilter(id: "all", title: "All")])
    }

    func detail(command: String, item: String, context: PrismContext) async throws -> ExtensionDetail {
        ExtensionDetail(metadata: [ExtensionMetadataRow(label: "Title", value: item)])
    }

    func perform(action: String, item: String, command: String, context: PrismContext) async throws -> ExtensionActionResult {
        guard action == "done" else { throw PrismExtensionError("No such action.") }
        let titles = await (try list(command: command, query: "", filter: nil, context: context)).items.map(\.title)
        await context.setState(.strings(titles.filter { $0 != item }), for: "todos")
        return .reload(message: "Done")
    }
}

@Suite("Extension lists")
struct ExtensionListTests {
    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try ExtensionWire.decode(type, from: Data(json.utf8))
    }

    @Test("a minimal list decodes with defaults, and the full form round-trips")
    func wireForm() throws {
        let minimal = try decode(ExtensionList.self, #"{"items":[{"id":"a","title":"A"}]}"#)
        #expect(minimal.filtering == .prism)
        #expect(minimal.showsDetail == false)
        #expect(minimal.items[0].actions.isEmpty && minimal.items[0].keywords.isEmpty)

        let full = try decode(ExtensionList.self, #"""
        {"items":[{"id":"a","title":"A","subtitle":"sub","icon":{"symbol":"star","tint":"yellow"},
          "accessories":[{"text":"3","symbol":"bubble","tint":"blue"}],"keywords":["x"],"section":"Today",
          "detail":{"markdown":"# A","metadata":[{"label":"Owner","value":"me"}]},
          "actions":[{"id":"open","title":"Open","kind":"open","url":"https://example.com/a"},
                     {"id":"rm","title":"Delete","style":"destructive","shortcut":"cmd+delete","confirmationMessage":"Gone for good."}]}],
         "filtering":"extension","searchPlaceholder":"Search","filters":[{"id":"mine","title":"Mine"}],
         "emptyMessage":{"title":"Nothing"},"fetchedAt":1760000000,"error":"Offline; showing cached items."}
        """#)
        #expect(full.showsDetail)
        #expect(full.fetchedAt == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(full.items[0].primaryAction?.kind == .open(url: URL(string: "https://example.com/a")!))
        #expect(full.items[0].action(id: "rm")?.shortcut?.description == "cmd+delete")
        #expect(try ExtensionWire.roundTrip(full) == full)
    }

    @Test("actions reject unsafe URLs and drop unusable shortcuts")
    func actionValidation() throws {
        #expect(throws: DecodingError.self) {
            try decode(ExtensionAction.self, #"{"id":"x","title":"X","kind":"open","url":"javascript:alert(1)"}"#)
        }
        #expect(throws: DecodingError.self) {
            try decode(ExtensionAction.self, #"{"id":"x","title":"X","kind":"copy"}"#)
        }
        #expect(throws: DecodingError.self) {
            try decode(ExtensionAction.self, #"{"id":"x","title":"X","kind":"grantFolder"}"#)
        }
        let grant = try decode(ExtensionAction.self, #"{"id":"allow","title":"Allow","kind":"grantFolder","folder":"notes"}"#)
        #expect(grant.kind == .grantFolder(id: "notes"))
        #expect(try ExtensionWire.roundTrip(grant) == grant)
        let plainKey = try decode(ExtensionAction.self, #"{"id":"x","title":"X","shortcut":"d"}"#)
        #expect(plainKey.shortcut == nil)
        #expect(ExtensionShortcut("Shift+CMD+C")?.description == "shift+cmd+c")
        #expect(ExtensionShortcut("ctrl+opt+5")?.modifiers == [.ctrl, .option])
        #expect(ExtensionShortcut("cmd+cmd+c") == nil)
        #expect(ExtensionShortcut("cmd+é") == nil)
        #expect(ExtensionShortcut("cmd+f13") == nil)
    }

    @Test("normalizing keeps the first of repeated IDs and caps the item count")
    func normalization() {
        let action = ExtensionAction(id: "a", title: "A")
        let list = ExtensionList(
            items: [
                ExtensionListItem(id: "1", title: "One", actions: [action, ExtensionAction(id: "a", title: "Again")]),
                ExtensionListItem(id: "1", title: "Duplicate"),
            ] + (2...1_200).map { ExtensionListItem(id: String($0), title: "Item") },
            filters: [ExtensionListFilter(id: "f", title: "F"), ExtensionListFilter(id: "f", title: "G")]
        ).normalized()
        #expect(list.items.count == ExtensionList.maximumItems)
        #expect(list.items[0].title == "One" && list.items[0].actions == [action])
        #expect(list.items[1].id == "2")
        #expect(list.filters.map(\.title) == ["F"])
    }

    @Test("action results carry the command result fields plus reload")
    func actionResults() throws {
        let reload = try decode(ExtensionActionResult.self, #"{"kind":"keepOpen","message":"Saved","reload":true}"#)
        #expect(reload == ExtensionActionResult(.keepOpen(message: "Saved"), reload: true))
        let done = try decode(ExtensionActionResult.self, #"{"kind":"completed"}"#)
        #expect(done == ExtensionActionResult(.completed(message: nil, restoreFocus: false)))
        #expect(try ExtensionWire.roundTrip(ExtensionActionResult.done) == .done)
    }

    @Test("the runtime serves lists, details, and actions that write state")
    func runtime() async throws {
        let recorder = OutputRecorder()
        let runtime = ExtensionRuntime(Todos(), output: { recorder.record($0) }, exit: {})
        func send(_ json: String) async { await runtime.receive(Data(json.utf8)) }
        await send(#"{"id":1,"method":"initialize","params":{"protocol":1,"prismVersion":"1.0","extensionID":"octocat.todos","preferences":{},"state":{}}}"#)
        await send(#"{"id":2,"method":"list.load","params":{"commandID":"todos","query":"mil"}}"#)
        await send(#"{"id":3,"method":"detail.load","params":{"commandID":"todos","itemID":"Walk"}}"#)
        await send(#"{"id":4,"method":"action.perform","params":{"commandID":"todos","itemID":"Buy milk","actionID":"done"}}"#)
        await send(#"{"id":5,"method":"action.perform","params":{"commandID":"todos","itemID":"Walk","actionID":"nope"}}"#)
        await send(#"{"id":6,"method":"list.load","params":{"commandID":"other"}}"#)
        await send(#"{"id":7,"method":"list.load","params":{}}"#)
        await runtime.waitForRequests()

        let list = try #require(recorder.response(2)?.result).decode(ExtensionList.self)
        #expect(list.items.map(\.id) == ["Buy milk"])
        #expect(list.showsDetail && list.filtering == .extension)
        let detail = try #require(recorder.response(3)?.result).decode(ExtensionDetail.self)
        #expect(detail.metadata == [ExtensionMetadataRow(label: "Title", value: "Walk")])

        let done = try #require(recorder.response(4)?.result).decode(ExtensionActionResult.self)
        #expect(done.reload)
        let write = try #require(recorder.notifications("state.write").first?.params).decode(ExtensionStateWriteParams.self)
        #expect(write == ExtensionStateWriteParams(requestID: 4, key: "todos", value: .strings(["Walk"])))

        let failed = try #require(recorder.response(5)?.result).decode(ExtensionActionResult.self)
        #expect(failed.result == .failed(message: "No such action."))
        #expect(recorder.response(6)?.error?.message == "No such list.")
        #expect(recorder.response(7)?.error?.message == "Invalid list.load parameters.")
    }
}
