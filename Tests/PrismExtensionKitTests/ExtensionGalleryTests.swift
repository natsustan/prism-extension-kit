import Foundation
import PrismExtensionProtocol
import Testing

@Suite("Gallery index")
struct ExtensionGalleryIndexTests {
    private static let manifest = ExtensionManifest(
        id: "octocat.sample", name: "Sample", version: "1.2.0", author: "octocat",
        icon: ExtensionIcon(symbol: "star", tint: "blue"), executable: "bin/Sample",
        commands: [ExtensionCommand(id: "run", title: "Run")]
    )

    private static func index() -> ExtensionGalleryIndex {
        ExtensionGalleryIndex(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            extensions: [ExtensionGalleryEntry(
                manifest: manifest,
                package: ExtensionGalleryPackage(
                    url: URL(string: "https://github.com/natsustan/prism-extensions/releases/download/x/sample.prismextension")!,
                    sha256: "ABCDEF", size: 1234
                ),
                publishedAt: Date(timeIntervalSince1970: 1_799_999_000),
                releaseNotes: "First release.",
                iconImage: Data("<svg/>".utf8)
            )],
            revoked: [ExtensionGalleryRevocation(id: "octocat.sample", versions: ["1.0.0"], reason: "Crashes.")]
        )
    }

    @Test("an index round-trips and finds entries and revocations")
    func roundTrip() throws {
        let index = Self.index()
        let decoded = try ExtensionWire.decode(ExtensionGalleryIndex.self, from: ExtensionWire.encode(index))
        #expect(decoded == index)
        #expect(decoded.entry(for: "octocat.sample")?.package.sha256 == "abcdef")
        #expect(decoded.entry(for: "octocat.sample")?.iconImage == Data("<svg/>".utf8))
        #expect(decoded.revocation(for: "octocat.sample", version: "1.0.0")?.reason == "Crashes.")
        #expect(decoded.revocation(for: "octocat.sample", version: "1.2.0") == nil)
    }

    @Test("a signature verifies the exact bytes with a known key, and nothing else")
    func signatures() throws {
        let keys = ExtensionGallerySigning.makeKeyPair()
        let other = ExtensionGallerySigning.makeKeyPair()
        let data = try ExtensionWire.encode(Self.index())
        let signature = try ExtensionGallerySigning.sign(data, privateKey: keys.privateKey, keyID: "2026-a")

        try ExtensionGallerySigning.verify(data, signature: signature, publicKeys: ["2026-a": keys.publicKey])
        var tampered = data
        tampered[tampered.startIndex] ^= 1
        #expect(throws: ExtensionGallerySigning.Failure.badSignature) {
            try ExtensionGallerySigning.verify(tampered, signature: signature, publicKeys: ["2026-a": keys.publicKey])
        }
        #expect(throws: ExtensionGallerySigning.Failure.badSignature) {
            try ExtensionGallerySigning.verify(data, signature: signature, publicKeys: ["2026-a": other.publicKey])
        }
        #expect(throws: ExtensionGallerySigning.Failure.unknownKey("2026-a")) {
            try ExtensionGallerySigning.verify(data, signature: signature, publicKeys: ["2025-z": keys.publicKey])
        }
        #expect(ExtensionGallerySigning.sha256(Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("versions compare numerically, component by component")
    func versions() {
        #expect(ExtensionVersion("1.10.0") > ExtensionVersion("1.9.3"))
        #expect(ExtensionVersion("1.2") == ExtensionVersion("1.2.0"))
        #expect(ExtensionVersion("2.0.0-beta") > ExtensionVersion("1.99"))
        #expect(!(ExtensionVersion("1.0.0") < ExtensionVersion("1.0")))
    }
}
