import Foundation
import Security
import CryptoKit

public enum UpdateArchive {
    public static func prepare(zip: URL, directory: URL, digest: String, expectedVersion: String) throws -> URL {
        let bytes = try Data(contentsOf: zip, options: .mappedIfSafe)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard "sha256:" + hash == digest else { throw failure("安装包校验失败") }
        let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, unpacked.path]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure("解压安装包失败") }
        let app = unpacked.appendingPathComponent("Hoot.app")
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == "com.xiezhaoye.shotpad",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion else { throw failure("安装包版本或应用标识不匹配") }
        if let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String {
            let current = ProcessInfo.processInfo.operatingSystemVersion
            let version = "\(current.majorVersion).\(current.minorVersion).\(current.patchVersion)"
            guard minimum.compare(version, options: .numeric) != .orderedDescending else { throw failure("新版本需要 macOS \(minimum) 或更新系统") }
        }
        var code: SecStaticCode?, requirement: SecRequirement?
        let expression = #"anchor apple generic and identifier "com.xiezhaoye.shotpad" and certificate leaf[subject.OU] = "KPMNP43ZN8""#
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), requirement) == errSecSuccess else { throw failure("安装包签名不属于 Hoot，已拒绝安装") }
        return app
    }
}
private func failure(_ message: String) -> NSError { NSError(domain: "Hoot.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
