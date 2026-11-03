import Foundation
import PrismExtensionKit
import PrismExtensionTesting
import Testing

@Suite("Extension localization")
struct ExtensionLocalizationTests {
    static let manifestJSON = """
    {
      "protocol": 1, "id": "octocat.coffee", "name": "Coffee", "version": "1.0.0", "author": "Octocat",
      "description": "Keep your Mac awake.",
      "icon": { "symbol": "cup.and.saucer.fill", "tint": "brown" },
      "commands": [
        { "id": "brew", "title": "Brew", "subtitle": "Coffee", "mode": "no-view", "keywords": ["awake"] },
        { "id": "stop", "title": "Stop Brewing", "mode": "no-view" }
      ],
      "preferences": [
        { "id": "disk", "type": "bool", "title": "Prevent Disk Sleep", "caption": "Disks too.", "section": "Power" }
      ],
      "widgets": [{ "id": "toggle", "title": "Coffee", "subtitle": "Keep awake", "template": "toggleCard" }],
      "folders": [{ "id": "beans", "path": "~/Beans", "reason": "Reads your beans." }],
      "localizations": {
        "zh-Hans": {
          "name": "咖啡",
          "description": "让 Mac 保持唤醒。",
          "commands": {
            "brew": { "title": "冲咖啡", "subtitle": "  ", "keywords": ["唤醒", ""] },
            "ghost": { "title": "不存在" }
          },
          "preferences": { "disk": { "title": "防止磁盘睡眠" } },
          "sections": { "Power": "电源" },
          "widgets": { "toggle": { "title": "咖啡" } },
          "folders": { "beans": { "reason": "读取咖啡豆。" } }
        },
        "zh-Hant": { "commands": "not an object", "name": "咖啡（繁）" },
        "ja": 42
      }
    }
    """

    static func manifest(_ json: String = manifestJSON) throws -> ExtensionManifest {
        try JSONDecoder().decode(ExtensionManifest.self, from: Data(json.utf8))
    }

    @Test("A language matches only itself, falling back to the untranslated text", arguments: [
        ("zh-Hans", ["zh-Hans"], "zh-Hans"),
        ("zh-Hant", ["zh-Hans"], nil),
        ("zh-Hant", ["zh-Hans", "zh-Hant"], "zh-Hant"),
        ("en", ["zh-Hans"], nil),
        ("en", ["en", "zh-Hans"], "en"),
        ("zh-Hans", ["zh-CN"], "zh-CN"),
        ("zh-Hant", ["zh-HK", "zh-Hans"], "zh-HK"),
        ("zh-Hans", [], nil),
    ] as [(String, [String], String?)])
    func languageMatch(language: String, available: [String], expected: String?) {
        #expect(ExtensionLanguage.match(language, in: available) == expected)
    }

    @Test("Nil or empty language uses the untranslated text")
    func noLanguage() {
        #expect(ExtensionLanguage.match(nil, in: ["zh-Hans"]) == nil)
        #expect(ExtensionLanguage.match("", in: ["zh-Hans"]) == nil)
    }

    @Test("Display text translates field by field and keeps the rest")
    func displayText() throws {
        let manifest = try Self.manifest()
        let text = manifest.displayText(for: "zh-Hans")
        #expect(text.language == "zh-Hans")
        #expect(text.name == "咖啡")
        #expect(text.summary == "让 Mac 保持唤醒。")
        let brew = try #require(manifest.command(id: "brew"))
        let stop = try #require(manifest.command(id: "stop"))
        #expect(text.title(of: brew) == "冲咖啡")
        // Blank translations fall back.
        #expect(text.subtitle(of: brew) == "Coffee")
        #expect(text.keywords(of: brew) == ["唤醒"])
        #expect(text.title(of: stop) == "Stop Brewing")
        #expect(text.keywords(of: stop).isEmpty)
        let disk = try #require(manifest.preference(id: "disk"))
        #expect(text.title(of: disk) == "防止磁盘睡眠")
        #expect(text.caption(of: disk) == "Disks too.")
        #expect(text.section("Power") == "电源")
        #expect(text.section("Other") == "Other")
        let widget = try #require(manifest.widget(id: "toggle"))
        #expect(text.title(of: widget) == "咖啡")
        #expect(text.subtitle(of: widget) == "Keep awake")
        #expect(text.reason(of: try #require(manifest.folder(id: "beans"))) == "读取咖啡豆。")
        // Identity is untouched.
        #expect(brew.title == "Brew")
        #expect(manifest.name == "Coffee")
    }

    @Test("Unreadable translations drop only themselves")
    func lenientDecoding() throws {
        let manifest = try Self.manifest()
        #expect(Set(manifest.localizations.keys) == ["zh-Hans", "zh-Hant"])
        let hant = try #require(manifest.localizations["zh-Hant"])
        #expect(hant.name == "咖啡（繁）")
        #expect(hant.commands.isEmpty)

        let broken = Self.manifestJSON.replacingOccurrences(
            of: "\"localizations\": {", with: "\"localizations\": [], \"unused\": {"
        )
        #expect(try Self.manifest(broken).localizations.isEmpty)
    }

    @Test("Traditional Chinese without its own text shows English, not Simplified")
    func traditionalFallsBack() throws {
        let manifest = try Self.manifest()
        let text = manifest.displayText(for: "zh-Hant")
        #expect(text.name == "咖啡（繁）")
        #expect(text.title(of: try #require(manifest.command(id: "brew"))) == "Brew")
        #expect(manifest.displayText(for: "en").name == "Coffee")
        #expect(manifest.displayText(for: nil).language == nil)
    }

    @Test("Translations survive encoding, and manifests without them gain no key")
    func roundTrip() throws {
        let manifest = try Self.manifest()
        let decoded = try JSONDecoder().decode(ExtensionManifest.self, from: JSONEncoder().encode(manifest))
        #expect(decoded == manifest)
        #expect(decoded.localizations["zh-Hans"]?.commands["brew"]?.keywords == ["唤醒", ""])

        let plain = ExtensionManifest(
            id: "octocat.plain", name: "Plain", version: "1.0", author: "Octocat",
            icon: ExtensionIcon(symbol: "star", tint: "blue")
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any]
        #expect(object?["localizations"] == nil)
        #expect(object?["description"] == nil)
    }

    @Test("References to undeclared items are reported for lint")
    func unknownReferences() throws {
        #expect(try Self.manifest().unknownLocalizationReferences() == [
            "localizations.zh-Hans.commands.ghost names no command in the manifest"
        ])
    }

    @Test("Every translated string is listed with its field")
    func allText() throws {
        let fields = try #require(try Self.manifest().localizations["zh-Hans"]).allText.map(\.field)
        #expect(fields.contains("commands.brew.subtitle"))
        #expect(fields.contains("sections.Power"))
        #expect(fields.contains("folders.beans.reason"))
    }
}

/// Answers with what it sees of Prism's language.
private struct LanguageEcho: PrismExtension {
    func run(command: String, context: PrismContext) async throws -> ExtensionCommandResult {
        // Code that has no context still sees the request's language.
        let inner = await Task { PrismLocalization.language ?? "none" }.value
        return .keepOpen(message: "\(context.language ?? "none") \(inner)")
    }

    func status(for command: String, context: PrismContext) async throws -> ExtensionRowStatus? {
        ExtensionRowStatus(text: PrismLocalization.language ?? "none")
    }
}

@Suite("Runtime language")
struct RuntimeLanguageTests {
    @Test("Requests see the language initialize sent, each host its own")
    func perHost() async throws {
        async let hans = PrismTestHost(LanguageEcho(), language: "zh-Hans").run("echo")
        async let hant = PrismTestHost(LanguageEcho(), language: "zh-Hant").run("echo")
        #expect(try await hans == .keepOpen(message: "zh-Hans zh-Hans"))
        #expect(try await hant == .keepOpen(message: "zh-Hant zh-Hant"))
    }

    @Test("Status reads see the language too")
    func status() async throws {
        let prism = try await PrismTestHost(LanguageEcho(), language: "zh-Hant")
        #expect(try await prism.status("row")?.text == "zh-Hant")
    }

    @Test("Test hosts default to English")
    func defaultLanguage() async throws {
        let prism = try await PrismTestHost(LanguageEcho())
        #expect(try await prism.run("echo") == .keepOpen(message: "en en"))
    }

    @Test("Locale keeps the user's region and takes Prism's language")
    func locale() {
        let locale = PrismLocalization.locale(for: "zh-Hant")
        #expect(locale.language.languageCode == "zh")
        #expect(locale.language.script == .hanTraditional)
        #expect(locale.region == Locale.current.region)
        #expect(PrismLocalization.locale(for: nil) == .current)
    }
}

@Suite("Localized bundles")
struct LocalizedBundleTests {
    /// A resource bundle laid out as SwiftPM builds one, with `en` and
    /// `zh-Hans` string tables.
    static func makeBundle(languages: [(String, String)] = [("en", "Hello"), ("zh-Hans", "你好")]) throws -> Bundle {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-localized-\(UUID().uuidString).bundle", isDirectory: true)
        for (language, value) in languages {
            let lproj = folder.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            try Data("\"Hello\" = \"\(value)\";\n".utf8).write(to: lproj.appendingPathComponent("Localizable.strings"))
        }
        return try #require(Bundle(url: folder))
    }

    @Test("Strings come from Prism's language, with English for an untranslated one", arguments: [
        ("zh-Hans", "你好"), ("zh-Hant", "Hello"), ("en", "Hello"), ("ja", "Hello"),
    ])
    func lookup(language: String, expected: String) throws {
        let bundle = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL) }
        let localized = PrismLocalization.bundle(bundle, language: language)
        #expect(String(localized: "Hello", bundle: localized) == expected)
    }

    @Test("A bundle without English strings still shows the text in code, whatever macOS uses")
    func noDevelopmentStrings() throws {
        let bundle = try Self.makeBundle(languages: [("zh-Hans", "你好")])
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL) }
        for language in ["en", "zh-Hant"] {
            let localized = PrismLocalization.bundle(bundle, language: language)
            #expect(localized !== bundle)
            #expect(String(localized: "Hello", bundle: localized) == "Hello")
        }
        #expect(String(localized: "Hello", bundle: PrismLocalization.bundle(bundle, language: "zh-Hans")) == "你好")
    }

    @Test("Without a language the bundle is used as is")
    func noLanguage() throws {
        let bundle = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL) }
        #expect(PrismLocalization.bundle(bundle, language: nil) === bundle)
    }

    @Test("prismLocalized follows the request's language")
    func taskLocal() throws {
        let bundle = try Self.makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle.bundleURL) }
        let text = PrismLocalization.$language.withValue("zh-Hans") {
            String(localized: "Hello", bundle: bundle.prismLocalized)
        }
        #expect(text == "你好")
    }
}
