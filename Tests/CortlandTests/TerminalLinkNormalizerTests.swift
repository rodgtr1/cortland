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

/// The whole decision a clicked cell triggers: editor, system opener, or
/// nothing. The "nothing" answers are the point — anything that isn't a file or
/// a real URL used to reach `NSWorkspace` as raw text, and LaunchServices
/// answers that with -50 and a Finder alert.
final class TerminalLinkTargetTests: XCTestCase {
    private static let cwd = "/Users/x/Repos/cortland"
    private static let onDisk: Set<String> = [
        "/private/tmp/scratch/notes.md",
        "/Users/x/Repos/cortland/Sources/Cortland/App/Log.swift",
        "/Users/x/notes/todo.txt",
        "/private/tmp/weird:12"
    ]

    private func target(_ raw: String, cwd: String = cwd) -> TerminalLinkTarget? {
        TerminalLinkNormalizer.target(for: raw, relativeTo: cwd) { Self.onDisk.contains($0) }
    }

    func testAbsolutePathOnDiskOpensInTheEditor() {
        XCTAssertEqual(
            target("/private/tmp/scratch/notes.md"),
            .file(path: "/private/tmp/scratch/notes.md", line: nil)
        )
    }

    func testRelativePathResolvesAgainstThePaneCWD() {
        XCTAssertEqual(
            target("Sources/Cortland/App/Log.swift"),
            .file(path: "/Users/x/Repos/cortland/Sources/Cortland/App/Log.swift", line: nil)
        )
        XCTAssertEqual(
            target("./Sources/Cortland/App/Log.swift"),
            .file(path: "/Users/x/Repos/cortland/Sources/Cortland/App/Log.swift", line: nil)
        )
    }

    func testLineAndColumnSuffixesAreStripped() {
        XCTAssertEqual(
            target("Sources/Cortland/App/Log.swift:120"),
            .file(path: "/Users/x/Repos/cortland/Sources/Cortland/App/Log.swift", line: 120)
        )
        XCTAssertEqual(
            target("Sources/Cortland/App/Log.swift:120:8"),
            .file(path: "/Users/x/Repos/cortland/Sources/Cortland/App/Log.swift", line: 120)
        )
    }

    func testAFileWhoseNameEndsInColonDigitsWinsOverTheLineReading() {
        XCTAssertEqual(target("/private/tmp/weird:12"), .file(path: "/private/tmp/weird:12", line: nil))
    }

    func testFileURLsOpenInTheEditorToo() {
        XCTAssertEqual(
            target("file:///private/tmp/scratch/notes.md"),
            .file(path: "/private/tmp/scratch/notes.md", line: nil)
        )
        XCTAssertEqual(
            target("file://localhost/private/tmp/scratch/notes.md"),
            .file(path: "/private/tmp/scratch/notes.md", line: nil)
        )
    }

    func testTildePathsExpand() {
        let home = NSString(string: "~").expandingTildeInPath
        let path = home + "/notes/todo.txt"
        let target = TerminalLinkNormalizer.target(for: "~/notes/todo.txt", relativeTo: Self.cwd) {
            $0 == path
        }
        XCTAssertEqual(target, .file(path: path, line: nil))
    }

    func testLinksStillGoToTheSystemOpener() {
        XCTAssertEqual(target("https://example.com/a"), .url(URL(string: "https://example.com/a")!))
        XCTAssertEqual(
            target("developers.cloudflare.com/docs"),
            .url(URL(string: "https://developers.cloudflare.com/docs")!)
        )
        XCTAssertEqual(target("mailto:travis@travis.media"), .url(URL(string: "mailto:travis@travis.media")!))
        XCTAssertEqual(target("ssh://host.example.com/x"), .url(URL(string: "ssh://host.example.com/x")!))
    }

    func testAFileOnDiskBeatsAHostnameReading() {
        // `notes.md` reads as a hostname (two labels, alphabetic TLD), but a file
        // by that name in the pane's cwd is what the click meant.
        let target = TerminalLinkNormalizer.target(for: "notes.md", relativeTo: "/private/tmp/scratch") {
            $0 == "/private/tmp/scratch/notes.md"
        }
        XCTAssertEqual(target, .file(path: "/private/tmp/scratch/notes.md", line: nil))
    }

    func testSchemelessNonFilesAreRefusedRatherThanSentToLaunchServices() {
        XCTAssertNil(target("/private/tmp/gone.md"))          // path, but not on disk
        XCTAssertNil(target("/etc"))                          // directory: fileExists says no
        XCTAssertNil(target("src/main.rs"))                   // unresolvable relative path
        XCTAssertNil(target("file:///private/tmp/gone.md"))   // file URL to nothing
        XCTAssertNil(target("note:something"))                // scheme-ish, no authority
        XCTAssertNil(target(""))
        XCTAssertNil(target("   "))
    }

    func testARelativePathWithNoCWDIsRefused() {
        XCTAssertNil(target("Sources/Cortland/App/Log.swift", cwd: ""))
    }
}
