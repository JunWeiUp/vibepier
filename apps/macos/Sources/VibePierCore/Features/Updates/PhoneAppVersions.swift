import CoreFoundation
import CryptoKit
import Foundation

/// Called only on SessionRemote's serial queue. Reports never change the available release.
final class PhoneAppVersions {
    static let packageName = "io.github.junweiup.vibepier.remote"
    struct Version: Codable, Equatable, Sendable {
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
    let root: URL
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
    struct Artifact: Sendable {
        let url: URL
        let version: Version
        let sha256: String
    }
    struct PreparedRelease: Sendable {
        let version: Version
        let apk: PreparedAPK
    }
    func requestedUpdate(_ request: [String: Any]) throws -> Artifact {
        guard request["packageName"] as? String == Self.packageName,
            let code = request["versionCode"] as? Int, (1...2_100_000_000).contains(code),
            CFGetTypeID(request["versionCode"] as AnyObject) != CFBooleanGetTypeID()
        else { throw CLIError(L10n.text("updates.invalid_metadata")) }
        guard let artifact = artifact else { throw CLIError(L10n.text("updates.no_release")) }
        guard artifact.version.versionCode > code else { throw CLIError(L10n.text("updates.no_newer_release")) }
        return artifact
    }
    var artifact: Artifact? {
        guard let release, let url = apkURL else { return nil }
        return Artifact(url: url, version: release.version, sha256: release.sha256)
    }
    /// File validation/copy/hash runs on the bounded preparation worker in production.
    static func prepare(_ apk: URL, root: URL, job: APKPreparationJob) throws -> PreparedRelease {
        try job.check()
        let metadata = apk.appendingPathExtension("json")
        let size = try metadata.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let metadataHandle = try FileHandle(forReadingFrom: metadata)
        defer { try? metadataHandle.close() }
        let metadataBytes = try metadataHandle.read(upToCount: 4097) ?? Data()
        guard size > 0, size <= 4096,
            !metadataBytes.isEmpty, metadataBytes.count <= 4096,
            let object = try JSONSerialization.jsonObject(with: metadataBytes) as? [String: Any],
            let expected = object["sha256"] as? String, expected.count == 64
        else { throw CLIError(L10n.text("updates.invalid_metadata")) }
        let version = try Version(object)
        let prepared = try PreparedAPK.prepare(apk, root: root, job: job)
        guard prepared.sha256 == expected else {
            prepared.discard()
            throw CLIError(L10n.text("updates.invalid_metadata"))
        }
        return PreparedRelease(version: version, apk: prepared)
    }
    /// Commit is serialized and rechecks version ordering after the asynchronous preparation.
    func adopt(_ prepared: PreparedRelease) throws {
        if let release {
            guard prepared.version.versionCode >= release.version.versionCode,
                prepared.version.versionCode != release.version.versionCode
                    || (prepared.version == release.version && prepared.apk.sha256 == release.sha256)
            else { throw CLIError(L10n.text("updates.increment_version")) }
        }
        let next = Release(
            version: prepared.version, sha256: prepared.apk.sha256, file: prepared.apk.file.lastPathComponent)
        try save(JSONEncoder().encode(next), name: "release.json")
        let old = release
        release = next
        if let old { try? FileManager.default.removeItem(at: root.appendingPathComponent(old.file)) }
    }
    /// Convenience for isolated store tests; app and local RPC use asynchronous preparation.
    func publish(_ apk: URL) throws {
        let prepared = try Self.prepare(apk, root: root, job: APKPreparationJob())
        do { try adopt(prepared) } catch {
            prepared.apk.discard()
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
