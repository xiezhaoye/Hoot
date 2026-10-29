import XCTest
import Foundation
import CryptoKit
@testable import ShotPadCore

final class UpdateArchiveTests: XCTestCase {
    func testTamperedDownloadIsRejectedBeforeExtraction() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("release.zip"); try Data("tampered".utf8).write(to: zip)
        XCTAssertThrowsError(try UpdateArchive.prepare(zip: zip, directory: dir, digest: "sha256:" + String(repeating: "0", count: 64), expectedVersion: "0.2.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("unpacked").path))
    }
    func testActualPublishedPackageSignatureAndVersion() throws {
        guard let path = ProcessInfo.processInfo.environment["HOOT_UPDATE_TEST_ARCHIVE"] else { throw XCTSkip("Set HOOT_UPDATE_TEST_ARCHIVE to validate a real signed release") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = URL(fileURLWithPath: path)
        let digest = "sha256:" + SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        let version = ProcessInfo.processInfo.environment["HOOT_UPDATE_TEST_VERSION"] ?? "0.1.0"
        let app = try UpdateArchive.prepare(zip: zip, directory: dir, digest: digest, expectedVersion: version)
        XCTAssertEqual(Bundle(url: app)?.bundleIdentifier, "com.xiezhaoye.shotpad")
        XCTAssertThrowsError(try UpdateArchive.prepare(zip: zip, directory: dir, digest: digest, expectedVersion: "99.0.0"))
    }
}
