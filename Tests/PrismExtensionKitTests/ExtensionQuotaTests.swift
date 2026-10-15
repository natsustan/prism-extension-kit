import Foundation
import PrismExtensionKit
import Testing

struct Agents: PrismExtension {
    func preferenceItems(_ preference: String, context: PrismContext) async throws -> [ExtensionPreferenceItem] {
        [ExtensionPreferenceItem(id: "codex", title: "Codex", badge: "Configured"),
         ExtensionPreferenceItem(id: "grok", title: "Grok", isOn: false)]
    }

    func run(command: String, context: PrismContext) async throws -> ExtensionCommandResult {
        await context.listChanged("usage")
        let enabled = context.preferences.orderedList("agents")
            .enabledIDs(with: try await preferenceItems("agents", context: context))
        return .keepOpen(message: enabled.joined(separator: ","))
    }
}

@Suite("Meters, quota widgets, and ordered lists")
struct ExtensionQuotaTests {
    private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
        try ExtensionWire.decode(type, from: Data(json.utf8))
    }

    @Test("meters clamp, default their tone, and round-trip with reset times")
    func meters() throws {
        let meter = try decode(ExtensionMeter.self, #"{"fraction":1.4,"resetsAt":1760000000}"#)
        #expect(meter.fraction == 1 && meter.tone == .normal)
        #expect(meter.resetsAt == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(try decode(ExtensionMeter.self, #"{"fraction":-2}"#).fraction == 0)
        let fractional = ExtensionMeter(fraction: 0.5, tone: .critical, resetsAt: Date(timeIntervalSince1970: 1_760_000_000.7))
        #expect(try ExtensionWire.roundTrip(fractional) == fractional)
    }

    @Test("detail headers, notices, sections with meters and dates, and loading items round-trip")
    func detail() throws {
        let detail = try decode(ExtensionDetail.self, #"""
        {"title":"Codex","subtitle":"Pro","icon":{"symbol":"bolt","tint":"blue","image":"ProviderIconCodex"},
         "updatedAt":1760000000,"notice":{"text":"Offline"},
         "sections":[{"title":"Limits","rows":[{"label":"5h","value":"58% left","meter":{"fraction":0.58,"resetsAt":1760003600}},
                                              {"label":"Plan","value":"Disabled","style":"badge"},
                                              {"label":"Expires","date":1760086400}]}]}
        """#)
        #expect(detail.icon?.image == "ProviderIconCodex")
        #expect(detail.notice == ExtensionNotice(text: "Offline", tone: .warning))
        #expect(detail.sections[0].rows[0].meter?.fraction == 0.58)
        #expect(detail.sections[0].rows[1].style == .badge)
        #expect(detail.sections[0].rows[2].value.isEmpty && detail.sections[0].rows[2].date != nil)
        #expect(!detail.isEmpty && ExtensionDetail().isEmpty)
        #expect(try ExtensionWire.roundTrip(detail) == detail)

        let item = try decode(ExtensionListItem.self, #"{"id":"codex","title":"Codex","isLoading":true,"accessories":[{"text":"58%","meter":{"fraction":0.58}}]}"#)
        #expect(item.isLoading && item.accessories[0].meter?.fraction == 0.58)
        #expect(try ExtensionWire.roundTrip(item) == item)
    }

    @Test("quota widget content decodes by template and keeps its open command")
    func quotaWidgets() throws {
        let content = try decode(ExtensionWidgetContent.self, #"""
        {"template":"quotaRings","openCommandID":"usage","items":[
          {"id":"codex","title":"Codex","value":"58%","meter":{"fraction":0.58,"tone":"warning"},"caption":"2h"},
          {"id":"grok","title":"Grok","value":"—","status":"Sign In"}]}
        """#)
        guard case let .quota(template, card) = content else {
            Issue.record("Expected a quota card")
            return
        }
        #expect(template == .quotaRings && template.quotaCapacity == 2)
        #expect(card.openCommandID == "usage" && card.items.map(\.id) == ["codex", "grok"])
        #expect(card.items[1].meter == nil && card.items[1].status == "Sign In")
        #expect(try ExtensionWire.roundTrip(content) == content)
        #expect(ExtensionWidgetTemplate.quotaRing.quotaCapacity == 1)
        #expect(!ExtensionWidgetTemplate.toggleCard.isQuota)
        #expect(try decode(ExtensionWidgetContent.self, #"{"template":"quotaBars"}"#)
            == .quota(.quotaBars, ExtensionQuotaCard(items: [])))
    }

    @Test("ordered lists keep the user's order and switches against changing items")
    func orderedLists() {
        let items = [
            ExtensionPreferenceItem(id: "codex", title: "Codex"),
            ExtensionPreferenceItem(id: "claude", title: "Claude", isOn: false),
            ExtensionPreferenceItem(id: "grok", title: "Grok"),
        ]
        let untouched = ExtensionOrderedList(value: nil)
        #expect(untouched.enabledIDs(with: items) == ["codex", "grok"])

        let stored = ExtensionOrderedList(value: .strings(["grok", "-codex", "gone", "grok"]))
        #expect(stored.entries.map(\.id) == ["grok", "codex", "gone"])
        #expect(stored.resolved(with: items).map(\.id) == ["grok", "codex", "claude"])
        #expect(stored.enabledIDs(with: items) == ["grok"])

        let switched = stored.setting("claude", isOn: true, items: items)
        #expect(switched.value == .strings(["grok", "-codex", "claude"]))
        let moved = switched.moving("claude", onto: "grok", items: items)
        #expect(moved.enabledIDs(with: items) == ["claude", "grok"])
        #expect(moved.moving("missing", onto: "grok", items: items) == moved)
    }

    @Test("preferences group by section in first-appearance order")
    func preferenceSections() throws {
        let manifest = try decode(ExtensionManifest.self, #"""
        {"protocol": 1, "id": "dev.example.agents", "name": "Agents", "version": "1.0.0", "author": "Example",
         "preferences": [
           {"id": "agents", "type": "orderedList", "title": "Shown Agents", "section": "Agents"},
           {"id": "compact", "type": "bool", "title": "Compact"},
           {"id": "key", "type": "secret", "title": "API Key", "section": "Account"},
           {"id": "remaining", "type": "bool", "title": "Remaining", "section": "Agents"},
           {"id": "plain", "type": "text", "title": "Plain", "section": ""}
         ]}
        """#)
        let sections = manifest.preferenceSections
        #expect(sections.map(\.title) == ["Agents", nil, "Account"])
        #expect(sections.map { $0.preferences.map(\.id) } == [["agents", "remaining"], ["compact", "plain"], ["key"]])
    }

    @Test("the runtime answers preferences.items and sends list.changed")
    func runtime() async throws {
        let recorder = OutputRecorder()
        let runtime = ExtensionRuntime(Agents(), output: { recorder.record($0) }, exit: {})
        func send(_ json: String) async { await runtime.receive(Data(json.utf8)) }
        await send(#"{"id":1,"method":"initialize","params":{"protocol":1,"prismVersion":"1","extensionID":"prism.agents","preferences":{"agents":["grok","-codex"]},"state":{}}}"#)
        await send(#"{"id":2,"method":"preferences.items","params":{"preferenceID":"agents"}}"#)
        await send(#"{"id":3,"method":"command.run","params":{"commandID":"refresh"}}"#)
        await runtime.waitForRequests()

        let items = try #require(recorder.response(2)?.result).decode(ExtensionPreferenceItems.self)
        #expect(items.items.map(\.id) == ["codex", "grok"] && items.items[0].badge == "Configured")
        let changed = try #require(recorder.notifications("list.changed").first?.params).decode(ExtensionListChangedParams.self)
        #expect(changed.commandID == "usage")
        #expect(try recorder.response(3)?.result?.decode(ExtensionCommandResult.self) == .keepOpen(message: "grok"))
    }
}
