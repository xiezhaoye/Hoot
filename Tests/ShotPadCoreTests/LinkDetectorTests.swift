import XCTest
@testable import ShotPadCore

final class LinkDetectorTests: XCTestCase {
    func testFindsURLs() {
        XCTAssertEqual(LinkDetector.firstURL(in: "https://example.com/a?b=1")?.absoluteString, "https://example.com/a?b=1")
        XCTAssertEqual(LinkDetector.firstURL(in: "请访问 example.com/path 了解")?.host, "example.com")
    }
    func testIgnoresNonWebText() {
        XCTAssertNil(LinkDetector.firstURL(in: "hello world"))
        XCTAssertNil(LinkDetector.firstURL(in: "mailto:a@b.com"))
    }
}
