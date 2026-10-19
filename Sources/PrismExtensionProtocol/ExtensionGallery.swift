import CryptoKit
import Foundation

/// The Gallery's catalog: `index.json`, published by the extensions
/// repository's release pipeline next to `index.json.sig`. Prism trusts an
/// entry only through the signature, which covers the file's exact bytes.
public struct ExtensionGalleryIndex: Hashable, Codable, Sendable {
    public static let currentFormat = 1

    /// The index layout; Prism ignores an index from a newer format.
    public var format: Int
    public var generatedAt: Date
    public var extensions: [ExtensionGalleryEntry]
    /// Published versions Prism must turn off, with the reason it shows.
    public var revoked: [ExtensionGalleryRevocation]

    public init(
        format: Int = currentFormat,
        generatedAt: Date,
        extensions: [ExtensionGalleryEntry],
        revoked: [ExtensionGalleryRevocation] = []
    ) {
        self.format = format
        self.generatedAt = ExtensionWireDate.rounded(generatedAt) ?? generatedAt
        self.extensions = extensions
        self.revoked = revoked
    }

    private enum CodingKeys: String, CodingKey {
        case format, generatedAt, extensions, revoked
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(Int.self, forKey: .format)
        generatedAt = try container.decodeDateIfPresent(forKey: .generatedAt) ?? Date(timeIntervalSince1970: 0)
        extensions = try container.decodeIfPresent([ExtensionGalleryEntry].self, forKey: .extensions) ?? []
        revoked = try container.decodeIfPresent([ExtensionGalleryRevocation].self, forKey: .revoked) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encodeDateIfPresent(generatedAt, forKey: .generatedAt)
        try container.encode(extensions, forKey: .extensions)
        try container.encode(revoked, forKey: .revoked)
    }

    public func entry(for id: ExtensionID) -> ExtensionGalleryEntry? {
        extensions.first { $0.id == id }
    }

    public func revocation(for id: ExtensionID, version: String) -> ExtensionGalleryRevocation? {
        revoked.first { $0.id == id && $0.versions.contains(version) }
    }
}

/// One extension's latest published version.
public struct ExtensionGalleryEntry: Hashable, Codable, Sendable, Identifiable {
    /// The packaged manifest, so the Gallery can show commands, widgets,
    /// preferences, and capabilities before anything is downloaded.
    public var manifest: ExtensionManifest
    public var package: ExtensionGalleryPackage
    public var publishedAt: Date?
    /// The extension's folder in the repository, for View Source.
    public var sourceURL: URL?
    /// This version's changelog entry.
    public var releaseNotes: String?
    /// The file `manifest.icon.image` names, carried in the signed index so
    /// the Gallery can draw the extension's mark before it is installed.
    public var iconImage: Data?

    public var id: ExtensionID { manifest.id }

    public init(
        manifest: ExtensionManifest,
        package: ExtensionGalleryPackage,
        publishedAt: Date? = nil,
        sourceURL: URL? = nil,
        releaseNotes: String? = nil,
        iconImage: Data? = nil
    ) {
        self.manifest = manifest
        self.package = package
        self.publishedAt = ExtensionWireDate.rounded(publishedAt)
        self.sourceURL = sourceURL
        self.releaseNotes = releaseNotes
        self.iconImage = iconImage
    }

    private enum CodingKeys: String, CodingKey {
        case manifest, package, publishedAt, sourceURL, releaseNotes, iconImage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try container.decode(ExtensionManifest.self, forKey: .manifest)
        package = try container.decode(ExtensionGalleryPackage.self, forKey: .package)
        publishedAt = try container.decodeDateIfPresent(forKey: .publishedAt)
        sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
        releaseNotes = try container.decodeIfPresent(String.self, forKey: .releaseNotes)
        // An icon Prism cannot read draws the symbol, as an unusable image does.
        iconImage = (try? container.decodeIfPresent(Data.self, forKey: .iconImage)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(manifest, forKey: .manifest)
        try container.encode(package, forKey: .package)
        try container.encodeDateIfPresent(publishedAt, forKey: .publishedAt)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try container.encodeIfPresent(releaseNotes, forKey: .releaseNotes)
        try container.encodeIfPresent(iconImage, forKey: .iconImage)
    }
}

/// Where a version's `.prismextension` lives and how to recognise it.
public struct ExtensionGalleryPackage: Hashable, Codable, Sendable {
    public var url: URL
    /// Lowercase hex SHA-256 of the package file.
    public var sha256: String
    public var size: Int

    public init(url: URL, sha256: String, size: Int) {
        self.url = url
        self.sha256 = sha256.lowercased()
        self.size = size
    }
}

public struct ExtensionGalleryRevocation: Hashable, Codable, Sendable {
    public var id: ExtensionID
    public var versions: [String]
    public var reason: String

    public init(id: ExtensionID, versions: [String], reason: String) {
        self.id = id
        self.versions = versions
        self.reason = reason
    }
}

// MARK: - Signing

/// `index.json.sig`: an Ed25519 signature over `index.json`'s bytes and the
/// ID of the key that made it, so keys can be rotated.
public struct ExtensionGallerySignature: Hashable, Codable, Sendable {
    public var keyID: String
    /// Base64 of the 64-byte signature.
    public var signature: String

    public init(keyID: String, signature: String) {
        self.keyID = keyID
        self.signature = signature
    }
}

public enum ExtensionGallerySigning {
    public enum Failure: Error, Equatable, Sendable {
        case unknownKey(String)
        case malformed
        case badSignature
    }

    /// Signs `data` with a raw 32-byte Ed25519 private key (base64).
    public static func sign(_ data: Data, privateKey: String, keyID: String) throws -> ExtensionGallerySignature {
        guard let raw = Data(base64Encoded: privateKey) else { throw Failure.malformed }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        return ExtensionGallerySignature(keyID: keyID, signature: try key.signature(for: data).base64EncodedString())
    }

    /// Checks `data` against a signature made by one of `publicKeys`
    /// (key ID → raw 32-byte public key, base64).
    public static func verify(
        _ data: Data, signature: ExtensionGallerySignature, publicKeys: [String: String]
    ) throws {
        guard let encodedKey = publicKeys[signature.keyID] else { throw Failure.unknownKey(signature.keyID) }
        guard let rawKey = Data(base64Encoded: encodedKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
              let rawSignature = Data(base64Encoded: signature.signature) else { throw Failure.malformed }
        guard key.isValidSignature(rawSignature, for: data) else { throw Failure.badSignature }
    }

    /// Lowercase hex SHA-256, as package entries record it.
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A new key pair, base64 raw representations: `(privateKey, publicKey)`.
    public static func makeKeyPair() -> (privateKey: String, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (key.rawRepresentation.base64EncodedString(), key.publicKey.rawRepresentation.base64EncodedString())
    }
}

// MARK: - Versions

/// Dotted numeric versions ("1.2.10"), compared component by component; a
/// missing component counts as zero. Anything after a component's digits is
/// ignored.
public struct ExtensionVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let description: String

    public init(_ string: String) {
        description = string
        components = string.split(separator: ".").map { part in
            Int(part.prefix(while: \.isNumber)) ?? 0
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}
