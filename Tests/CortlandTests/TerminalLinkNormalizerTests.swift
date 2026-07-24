import XCTest
@testable import Cortland

/// Covers the line between "clicked text is a link" and "clicked text is a file
/// path". Get it wrong one way and schemeless links reach NSWorkspace, which
/// refuses them with -50; wrong the other way and a ⌘+click on a source path
/// launches a browser.
final class TerminalLinkNormalizerTests: XCTestCase {
    private func url(_ raw: String) -> String? {
        TerminalLinkNormalizer.openableURL(from: raw)?.absoluteString
    }

    func testSchemedLinksPassThrough() {
        XCTAssertEqual(url("https://example.com/a"), "https://example.com/a")
        XCTAssertEqual(url("http://localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(url("HTTPS://Example.com/A"), "HTTPS://Example.com/A")
    }

    func testSchemelessHostsArePromotedToHTTPS() {
        XCTAssertEqual(
            url("developers.cloudflare.com/docs-for-agents/"),
            "https://developers.cloudflare.com/docs-for-agents/"
        )
        XCTAssertEqual(url("www.example.co.uk/x?y=1"), "https://www.example.co.uk/x?y=1")
        XCTAssertEqual(url("example.com:8080/status"), "https://example.com:8080/status")
    }

    func testTrailingProsePunctuationIsTrimmed() {
        XCTAssertEqual(url("https://example.com/a."), "https://example.com/a")
        XCTAssertEqual(url("developers.cloudflare.com/docs,"), "https://developers.cloudflare.com/docs")
    }

    func testFilePathsAreNotLinks() {
        XCTAssertNil(url("src/main.rs"))
        XCTAssertNil(url("Sources/Cortland/App/Log.swift"))
        XCTAssertNil(url("./build/out.tar.gz"))
        XCTAssertNil(url("~/Repos/cortland-term-mac"))
        XCTAssertNil(url("/usr/local/bin/swift"))
    }

    func testNonHTTPSchemesAreRefused() {
        // Left for SwiftTerm's own handler, which opens them in Mail/Finder.
        XCTAssertNil(url("mailto:travis@travis.media"))
        XCTAssertNil(url("file:///etc/hosts"))
        XCTAssertNil(url("ssh://host.example.com/x"))
    }

    func testMalformedAuthoritiesAreRefused() {
        XCTAssertNil(url(""))
        XCTAssertNil(url("..."))
        XCTAssertNil(url("example./path"))
        XCTAssertNil(url("-example.com/path"))
        XCTAssertNil(url("example.c/path"))       // one-letter TLD
        XCTAssertNil(url("example.com:80x/path")) // port isn't digits
        XCTAssertNil(url("example.123/path"))     // numeric TLD
    }
}
