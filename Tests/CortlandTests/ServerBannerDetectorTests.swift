import XCTest
@testable import Cortland

final class ServerBannerDetectorTests: XCTestCase {
    func testDetectsLocalhostURL() {
        var detector = ServerBannerDetector()
        let url = detector.detectServerURL(in: "Server running at http://localhost:3000/")
        XCTAssertEqual(url?.absoluteString, "http://localhost:3000/")
    }

    func testNormalizesBindAllAddressesToLocalhost() {
        var detector = ServerBannerDetector()
        XCTAssertEqual(detector.detectServerURL(in: "on http://0.0.0.0:8080")?.host, "localhost")
        var second = ServerBannerDetector()
        XCTAssertEqual(second.detectServerURL(in: "on http://127.0.0.1:8080")?.host, "localhost")
    }

    func testListeningOnPortFallback() {
        var detector = ServerBannerDetector()
        let url = detector.detectServerURL(in: "Listening on port 4000")
        XCTAssertEqual(url?.absoluteString, "http://localhost:4000/")
    }

    func testLowPortsFromListeningLineAreIgnored() {
        var detector = ServerBannerDetector()
        XCTAssertNil(detector.detectServerURL(in: "listening on port 79"))
    }

    func testDedupsRepeatedURLButOffersNewOne() {
        var detector = ServerBannerDetector()
        XCTAssertNotNil(detector.detectServerURL(in: "http://localhost:3000/"))
        XCTAssertNil(detector.detectServerURL(in: "still at http://localhost:3000/"))
        XCTAssertNotNil(detector.detectServerURL(in: "now at http://localhost:5173/"))
    }

    func testIgnoresNonLocalURLs() {
        var detector = ServerBannerDetector()
        XCTAssertNil(detector.detectServerURL(in: "see https://example.com/docs for more"))
    }

    func testPlainOutputWithoutLiteralsIsCheap() {
        var detector = ServerBannerDetector()
        XCTAssertNil(detector.detectServerURL(in: "compiling module 42 of 97"))
    }

    func testStripsANSIBeforeMatching() {
        var detector = ServerBannerDetector()
        let output = "\u{001B}[32m➜\u{001B}[0m  Local: \u{001B}[36mhttp://localhost:3000/\u{001B}[0m"
        XCTAssertEqual(detector.detectServerURL(in: output)?.port, 3000)
    }
}
