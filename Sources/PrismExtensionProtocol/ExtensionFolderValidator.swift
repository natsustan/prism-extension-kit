import Darwin
import Foundation

/// Reads and checks an extension directory (`manifest.json` plus its
/// executable). Prism's local import, live reload, and Validate action use it,
/// and so does the extensions repository's lint, so both enforce the same rules.
public enum ExtensionFolderValidator {
    public static let manifestFileName = "manifest.json"
    public static let manifestSizeLimit = 256 * 1024

    public struct Failure: Error, Equatable, Sendable {
        public let message: String

        public init(message: String) {
            self.message = message
        }
    }

    /// The validated manifest of the extension in `directory`. The `prism.`
    /// namespace is accepted only for first-party extensions.
    public static func manifest(in directory: URL, allowsReservedNamespace: Bool = false) throws -> ExtensionManifest {
        let url = directory.appendingPathComponent(manifestFileName)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw Failure(message: "No manifest.json in \(directory.lastPathComponent).")
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw Failure(message: "manifest.json must be a regular file.")
        }
        guard (attributes[.size] as? Int ?? 0) <= manifestSizeLimit else {
            throw Failure(message: "manifest.json is larger than 256 KB.")
        }
        let manifest: ExtensionManifest
        do {
            manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: url))
        } catch let DecodingError.keyNotFound(key, _) {
            throw Failure(message: "manifest.json is missing “\(key.stringValue)”.")
        } catch let DecodingError.dataCorrupted(context) where context.codingPath.isEmpty {
            throw Failure(message: "manifest.json is not valid JSON: \(context.debugDescription)")
        } catch let DecodingError.dataCorrupted(context) {
            // Valid JSON with a value Prism does not support, such as an unknown
            // preference type.
            throw Failure(message: "manifest.json has an unsupported value at “\(path(context.codingPath))”.")
        } catch {
            throw Failure(message: "manifest.json could not be read: \(error.localizedDescription)")
        }
        do {
            try manifest.validate(allowsReservedNamespace: allowsReservedNamespace)
        } catch let error as ExtensionManifestError {
            throw Failure(message: describe(error))
        }
        _ = try executableURL(of: manifest, in: directory)
        return manifest
    }

    /// The executable inside `directory`: a relative path that resolves to a
    /// regular, executable file within the directory.
    public static func executableURL(of manifest: ExtensionManifest, in directory: URL) throws -> URL {
        guard let relative = manifest.executable, !relative.isEmpty else {
            throw Failure(message: "The manifest has no “executable”.")
        }
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
            throw Failure(message: "“executable” must be a path inside the extension folder.")
        }
        let candidate = directory.appendingPathComponent(relative)
        var info = stat()
        guard stat(candidate.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            if relative.hasPrefix(".build/") {
                throw Failure(message: "The executable \(relative) was not found. Run swift build -c release in the folder first.")
            }
            throw Failure(message: "The executable \(relative) was not found.")
        }
        // Symbolic links may point anywhere; the resolved file must stay inside.
        let root = resolved(directory)
        let url = URL(fileURLWithPath: resolved(candidate))
        guard url.path.hasPrefix(root + "/") else {
            throw Failure(message: "“executable” resolves outside the extension folder.")
        }
        guard access(url.path, X_OK) == 0 else {
            throw Failure(message: "\(relative) is not executable. Run chmod +x on it.")
        }
        return url
    }

    private static func resolved(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else { return url.standardizedFileURL.path }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    /// `preferences[0].type` for a decoding path.
    private static func path(_ codingPath: [any CodingKey]) -> String {
        codingPath.reduce(into: "") { path, key in
            if let index = key.intValue {
                path += "[\(index)]"
            } else {
                path += path.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
    }

    public static func describe(_ error: ExtensionManifestError) -> String {
        switch error {
        case let .unsupportedProtocol(version):
            "The extension needs protocol \(version); this Prism supports \(ExtensionManifest.supportedProtocolVersion)."
        case let .invalidID(id):
            "“\(id)” is not a valid extension ID. Use lowercase owner.name, such as octocat.focus-flag."
        case let .reservedID(id):
            "“\(id)” uses the prism. namespace, which is reserved for Prism's own extensions."
        case let .emptyField(field):
            "The manifest field “\(field)” is empty."
        case let .duplicateID(kind, id):
            "Two \(kind)s share the ID “\(id)”."
        case let .invalidItemID(kind, id):
            "“\(id)” is not a valid \(kind) ID. Use letters, digits, - and _."
        case let .invalidTaskExecutable(path):
            "Task executable \(path) must be an absolute path."
        case let .invalidFolderPath(path):
            "Folder \(path) must be an absolute path or start with ~/, without . or .. steps."
        case let .invalidPreferenceDefault(id, type):
            "The default of preference “\(id)” is not a \(type.defaultDescription)."
        }
    }
}
