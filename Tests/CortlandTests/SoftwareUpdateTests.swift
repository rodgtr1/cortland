import XCTest
@testable import Cortland

/// The self-update contract: what `Info.plist` promises Sparkle, and what
/// `scripts/make-appcast.sh` has to emit for a shipped build to accept an
/// update.
///
/// These are the parts that fail silently. A missing `SUPublicEDKey` disables
/// updates with nothing but a log line; a `CFBundleVersion` that doesn't move
/// leaves every existing install stranded on the old build with no error
/// anywhere. Both are cheap to assert and expensive to notice in the wild.
final class SoftwareUpdateTests: XCTestCase {

    /// The repo's checked-in `Info.plist` — the one `build-app.sh` copies into
    /// the bundle verbatim, so asserting on it is asserting on the build.
    private var repoInfoPlist: [String: Any] {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // CortlandTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // repo root
            let data = try Data(contentsOf: root.appendingPathComponent("Info.plist"))
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            return try XCTUnwrap(plist as? [String: Any])
        }
    }

    // MARK: - Info.plist

    func testShippedInfoPlistConfiguresSparkle() throws {
        let settings = SoftwareUpdateSettings(infoDictionary: try repoInfoPlist)
        XCTAssertNil(settings.unconfiguredReason)
        XCTAssertEqual(
            settings.feedURL,
            "https://github.com/rodgtr1/cortland/releases/latest/download/appcast.xml"
        )
    }

    /// The public key is half of a keypair whose private half exists only in a
    /// Keychain. Changing it strands every install that shipped with the old
    /// one, so it is pinned here rather than merely shape-checked.
    func testPublicKeyIsPinned() throws {
        let settings = SoftwareUpdateSettings(infoDictionary: try repoInfoPlist)
        XCTAssertEqual(settings.publicEDKey, "W5Jn7EJ/28kZ5Ml4wblCLvlr9N3Ih5pX2fs5SznPA98=")
    }

    // MARK: - Version monotonicity

    /// `CFBundleVersion` is what Sparkle compares; `CFBundleShortVersionString`
    /// is what people read. They are bumped by hand, in two places, which is
    /// exactly the kind of edit that gets half-done. The formula is
    /// minor × 100 + patch (docs/release-baseline.md).
    func testBundleVersionMatchesShortVersionFormula() throws {
        let plist = try repoInfoPlist
        let short = try XCTUnwrap(plist["CFBundleShortVersionString"] as? String)
        let build = try XCTUnwrap(plist["CFBundleVersion"] as? String)

        let parts = short.split(separator: ".").map { Int($0) ?? -1 }
        XCTAssertEqual(parts.count, 3, "version \(short) is not major.minor.patch")
        XCTAssertEqual(parts[0], 0, "the minor×100+patch formula has no room for a major bump; see docs/release-baseline.md")
        XCTAssertTrue(parts.allSatisfy { $0 >= 0 }, "version \(short) has a non-numeric component")
        XCTAssertLessThan(parts[2], 100, "the formula reserves 100 patch slots per minor")

        XCTAssertEqual(
            Int(build),
            parts[1] * 100 + parts[2],
            "CFBundleVersion \(build) does not match \(short) under minor×100+patch"
        )
    }

    // MARK: - Settings validation

    private func settings(feed: String?, key: String?) -> SoftwareUpdateSettings {
        var dict: [String: Any] = [:]
        if let feed { dict["SUFeedURL"] = feed }
        if let key { dict["SUPublicEDKey"] = key }
        return SoftwareUpdateSettings(infoDictionary: dict)
    }

    private let validKey = "W5Jn7EJ/28kZ5Ml4wblCLvlr9N3Ih5pX2fs5SznPA98="

    /// An unbundled `swift run` build has neither key. That is not a failure to
    /// report — it just means the menu item stays disabled.
    func testEmptyInfoDictionaryIsUnconfiguredNotFatal() {
        let settings = SoftwareUpdateSettings(infoDictionary: nil)
        XCTAssertFalse(settings.isConfigured)
        XCTAssertNotNil(settings.unconfiguredReason)
    }

    func testMissingKeyOrFeedIsUnconfigured() {
        XCTAssertFalse(settings(feed: "https://example.com/appcast.xml", key: nil).isConfigured)
        XCTAssertFalse(settings(feed: nil, key: validKey).isConfigured)
        XCTAssertFalse(settings(feed: "", key: validKey).isConfigured)
    }

    /// Sparkle refuses plain http feeds — a feed served over http is a feed
    /// anyone on the path can rewrite. Localhost is the one exception, which is
    /// what makes the offline test in docs/release.md possible.
    func testPlainHTTPIsRejectedExceptOnLocalhost() {
        XCTAssertFalse(settings(feed: "http://example.com/appcast.xml", key: validKey).isConfigured)
        XCTAssertTrue(settings(feed: "http://localhost:8917/appcast.xml", key: validKey).isConfigured)
        XCTAssertTrue(settings(feed: "http://127.0.0.1:8917/appcast.xml", key: validKey).isConfigured)
        XCTAssertTrue(settings(feed: "https://example.com/appcast.xml", key: validKey).isConfigured)
    }

    /// Ed25519 public keys are 32 bytes. A truncated or mistyped one would
    /// otherwise reach Sparkle and fail at download time, long after launch.
    func testPublicKeyMustBe32Base64Bytes() {
        XCTAssertFalse(settings(feed: "https://example.com/a.xml", key: "not base64!!").isConfigured)
        XCTAssertFalse(settings(feed: "https://example.com/a.xml", key: "c2hvcnQ=").isConfigured)
        XCTAssertFalse(settings(feed: "https://example.com/a.xml", key: "").isConfigured)
    }

    // MARK: - Appcast shape

    /// A golden copy of what `scripts/make-appcast.sh` emits, captured from a
    /// real run. It pins the four things a shipped build actually needs: the
    /// build number to compare, the URL to fetch, the signature to verify it
    /// with, and a length Sparkle checks the download against.
    private let sampleAppcast = """
    <?xml version="1.0" standalone="yes"?>
    <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
        <channel>
            <title>Cortland</title>
            <item>
                <title>0.5.0</title>
                <pubDate>Fri, 24 Jul 2026 10:10:30 -0400</pubDate>
                <link>https://github.com/rodgtr1/cortland</link>
                <sparkle:fullReleaseNotesLink>https://github.com/rodgtr1/cortland/blob/main/CHANGELOG.md</sparkle:fullReleaseNotesLink>
                <sparkle:version>500</sparkle:version>
                <sparkle:shortVersionString>0.5.0</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
                <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
                <enclosure url="https://github.com/rodgtr1/cortland/releases/download/v0.5.0/Cortland-0.5.0.dmg" length="5563672" type="application/octet-stream" sparkle:edSignature="Gboniq0gADamVJAbS9wqB+LJSZGvax7sGbdKtDv2mjs8O1fh1S9bVuxHQQkl286jBd0IepkoWhkkrM/FEIWtDA=="/>
            </item>
        </channel>
    </rss>
    """

    func testGeneratedAppcastCarriesEverythingAnUpdateNeeds() throws {
        let item = try XCTUnwrap(AppcastProbe.parseFirstItem(sampleAppcast))

        XCTAssertEqual(item.version, "500")
        XCTAssertEqual(item.shortVersion, "0.5.0")
        XCTAssertEqual(item.minimumSystemVersion, "13.0")
        XCTAssertEqual(item.length, 5563672)

        // The enclosure has to sit under the release tag matching its version,
        // or the feed points at an asset that release never carried.
        XCTAssertEqual(
            item.enclosureURL,
            "https://github.com/rodgtr1/cortland/releases/download/v0.5.0/Cortland-0.5.0.dmg"
        )

        // An unsigned item is one every client refuses; make-appcast.sh fails
        // the build over it, and this pins what it is checking for.
        let signature = try XCTUnwrap(item.edSignature)
        let decoded = try XCTUnwrap(Data(base64Encoded: signature))
        XCTAssertEqual(decoded.count, 64, "Ed25519 signatures are 64 bytes")
    }

    func testAppcastWithoutSignatureIsRecognisedAsUnusable() throws {
        let unsigned = sampleAppcast.replacingOccurrences(
            of: #" sparkle:edSignature="Gboniq0gADamVJAbS9wqB+LJSZGvax7sGbdKtDv2mjs8O1fh1S9bVuxHQQkl286jBd0IepkoWhkkrM/FEIWtDA==""#,
            with: ""
        )
        let item = try XCTUnwrap(AppcastProbe.parseFirstItem(unsigned))
        XCTAssertNil(item.edSignature)
        XCTAssertEqual(item.version, "500", "the rest of the item still parses")
    }
}

/// Minimal appcast reader for the tests above. Sparkle does the real parsing at
/// runtime; this exists only to assert on what our own generator wrote.
private enum AppcastProbe {
    struct Item {
        var version: String?
        var shortVersion: String?
        var minimumSystemVersion: String?
        var enclosureURL: String?
        var edSignature: String?
        var length: Int?
    }

    static func parseFirstItem(_ xml: String) -> Item? {
        let parser = XMLParser(data: Data(xml.utf8))
        let delegate = Collector()
        parser.delegate = delegate
        guard parser.parse(), delegate.sawItem else { return nil }
        return delegate.item
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var item = Item()
        var sawItem = false
        private var element = ""
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
            element = qName ?? elementName
            text = ""
            if element == "item" { sawItem = true }
            if element == "enclosure" {
                item.enclosureURL = attributes["url"]
                item.edSignature = attributes["sparkle:edSignature"]
                item.length = attributes["length"].flatMap(Int.init)
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch qName ?? elementName {
            case "sparkle:version": item.version = value
            case "sparkle:shortVersionString": item.shortVersion = value
            case "sparkle:minimumSystemVersion": item.minimumSystemVersion = value
            default: break
            }
            text = ""
        }
    }
}
