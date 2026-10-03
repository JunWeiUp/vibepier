import CoreFoundation
import CryptoKit
import Foundation

/// Called only on SessionRemote's serial queue. Reports never change the available release.
final class PhoneAppVersions {
    static let packageName = "io.github.junweiup.vibepier.remote"
    struct Version: Codable, Equatable {
        let versionCode: Int
        let versionName: String
        var object: [String: Any] { ["versionCode": versionCode, "versionName": versionName] }
        init(_ value: [String: Any]) throws {
            guard value["packageName"] as? String == PhoneAppVersions.packageName,
                let code = value["versionCode"] as? Int, (1...2_100_000_000).contains(code),
                CFGetTypeID(value["versionCode"] as AnyObject) != CFBooleanGetTypeID(),
                let name = value["versionName"] as? String, !name.isEmpty, name.utf8.count <= 80,
                !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw CLIError(L10n.text("updates.invalid_metadata")) }
            versionCode = code
            versionName = name
        }
    }
    private struct Release: Codable {
        let version: Version
        let sha256: String
        let file: String
    }
    private let root: URL
    private var release: Release?
    private var reports: [String: Version] = [:]
    init(root: URL = Paths.supportDirectory.appendingPathComponent("android-versions")) {
        self.root = root
        if let data = try? Data(contentsOf: root.appendingPathComponent("release.json")), data.count <= 4096 {
            release = try? JSONDecoder().decode(Release.self, from: data)
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("phones.json")), data.count <= 256 * 1024 {
            reports = (try? JSONDecoder().decode([String: Version].self, from: data)) ?? [:]
        }
    }
    var latest: [String: Any]? {
        guard let release, FileManager.default.fileExists(atPath: root.appendingPathComponent(release.file).path) else {
            return nil
        }
        return release.version.object
    }
    var apkURL: URL? { latest == nil ? nil : release.map { root.appendingPathComponent($0.file) } }
    func installed(_ device: String) -> [String: Any]? { reports[device]?.object }
    func report(_ request: [String: Any], device: String) throws -> [String: Any] {
        let version = try Version(request)
        if reports[device] != version {
            guard reports[device] != nil || reports.count < 256 else {
                throw CLIError(L10n.text("updates.invalid_metadata"))
            }
            var next = reports
            next[device] = version
            try save(JSONEncoder().encode(next), name: "phones.json")
            reports = next
        }
        var reply: [String: Any] = ["ok": true]
        if let latest { reply["latest"] = latest }
        return reply
    }
    func revoke(_ device: String) {
        reports.removeValue(forKey: device)
        try? save(JSONEncoder().encode(reports), name: "phones.json")
    }
    /// Explicit local operation, never performed by a build or by a phone report.
    func publish(_ apk: URL) throws {
        let metadata = apk.appendingPathExtension("json")
        let size = try metadata.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 4096,
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any],
            let expected = object["sha256"] as? String, expected.count == 64
        else { throw CLIError(L10n.text("updates.invalid_metadata")) }
        let version = try Version(object)
        if let release {
            guard version.versionCode >= release.version.versionCode,
                version.versionCode != release.version.versionCode
                    || (version == release.version && expected == release.sha256)
            else { throw CLIError(L10n.text("updates.increment_version")) }
        }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = UUID().uuidString + ".apk"
        let snapshot = root.appendingPathComponent(file)
        try FileManager.default.copyItem(at: apk, to: snapshot)
        do {
            let handle = try FileHandle(forReadingFrom: snapshot)
            defer { try? handle.close() }
            var hash = SHA256()
            var total = 0
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                total += data.count
                guard total <= PhoneAPK.maxSize else { throw CLIError(L10n.text("updates.invalid_metadata")) }
                hash.update(data: data)
            }
            guard total > 0, hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
                throw CLIError(L10n.text("updates.invalid_metadata"))
            }
            let next = Release(version: version, sha256: expected, file: file)
            try save(JSONEncoder().encode(next), name: "release.json")
            let old = release
            release = next
            if let old { try? FileManager.default.removeItem(at: root.appendingPathComponent(old.file)) }
        } catch {
            try? FileManager.default.removeItem(at: snapshot)
            throw error
        }
    }
    private func save(_ data: Data, name: String) throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: root.appendingPathComponent(name), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent(name).path)
    }
}
