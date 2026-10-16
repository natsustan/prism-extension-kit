import Foundation
import PrismExtensionProtocol
import Testing

@Suite("Extension folder validation")
struct ExtensionFolderValidatorTests {
    /// A temporary extension folder with `bin/run`.
    private struct Folder {
        let url: URL

        init(manifest: String?, executable: Bool = true) throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("prism-validator-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent("bin"), withIntermediateDirectories: true
            )
            let run = url.appendingPathComponent("bin/run")
            try "#!/bin/sh\n".write(to: run, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: run.path
            )
            if let manifest {
                try manifest.write(to: url.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            }
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    private static func manifest(
        id: String = "octocat.sample", executable: String = "bin/run", preferences: String = "[]"
    ) -> String {
        """
        { "protocol": 1, "id": "\(id)", "name": "Sample", "version": "1.0.0", "author": "octocat",
          "executable": "\(executable)", "commands": [{ "id": "run", "title": "Run", "mode": "no-view" }],
          "preferences": \(preferences) }
        """
    }

    private func failure(_ folder: Folder) -> String? {
        do {
            _ = try ExtensionFolderValidator.manifest(in: folder.url)
            return nil
        } catch let failure as ExtensionFolderValidator.Failure {
            return failure.message
        } catch {
            return "\(error)"
        }
    }

    @Test("a folder with a valid manifest and an executable inside it passes")
    func valid() throws {
        let folder = try Folder(manifest: Self.manifest())
        defer { folder.remove() }
        let manifest = try ExtensionFolderValidator.manifest(in: folder.url)
        #expect(manifest.id == "octocat.sample")
    }

    @Test("each broken folder names what to fix")
    func failures() throws {
        let cases: [(Folder, String)] = [
            (try Folder(manifest: nil), "No manifest.json"),
            (try Folder(manifest: "{"), "not valid JSON"),
            (try Folder(manifest: Self.manifest(id: "Not An ID")), "not a valid extension ID"),
            (try Folder(manifest: Self.manifest(id: "prism.sample")), "reserved"),
            (try Folder(manifest: Self.manifest(executable: "../run")), "inside the extension folder"),
            (try Folder(manifest: Self.manifest(executable: "bin/missing")), "was not found"),
            (try Folder(manifest: Self.manifest(), executable: false), "chmod +x"),
            // Pickers have no way to declare their options yet.
            (try Folder(manifest: Self.manifest(preferences: #"[{ "id": "mode", "type": "picker", "title": "Mode" }]"#)),
             "unsupported value at “preferences[0].type”"),
        ]
        defer { cases.forEach { $0.0.remove() } }
        for (folder, expected) in cases {
            let message = failure(folder)
            #expect(message?.contains(expected) == true, "\(message ?? "passed") should mention \(expected)")
        }
    }
}
