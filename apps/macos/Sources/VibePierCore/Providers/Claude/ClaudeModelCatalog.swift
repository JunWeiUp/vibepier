import Foundation

/// Read-only discovery from the same user configuration as headless Claude. No prompts or credentials leave the Mac.
/// Confined to ClaudeBridge's serial queue; tests inject both credential and HTTP readers.
final class ClaudeModelCatalog {
    typealias Fetch = (URLRequest) throws -> Data
    private let directory: URL
    private let environment: [String: String]
    private let helper: (String) throws -> String
    private let fetch: Fetch
    private var cache: (fingerprint: Data, until: TimeInterval, entries: [[String: Any]])?

    static var unavailable: CLIError { CLIError(L10n.text("provider.claude_model_catalog_unavailable")) }
    static var defaultEntry: [String: Any] {
        [
            "id": "default", "name": L10n.text("provider.default_model"), "efforts": ["default"],
            "defaultEffort": "default",
        ]
    }

    init(
        directory: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
        helper: @escaping (String) throws -> String = { command in
            let data = try RuntimeSubprocess.capture(
                URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command], timeout: 5)
            guard let token = String(data: data, encoding: .utf8) else { throw unavailable }
            return token.trimmingCharacters(in: .whitespacesAndNewlines)
        }, fetch: @escaping Fetch = { try ClaudeModelHTTP.read($0) }
    ) {
        self.directory =
            directory ?? URL(fileURLWithPath: environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude")
        self.environment = environment
        self.helper = helper
        self.fetch = fetch
    }

    func entries(cwd: String, refresh: Bool = false) throws -> [[String: Any]] {
        do {
            let settings = try readSettings(directory.appendingPathComponent("settings.json"))
            // Never execute project-controlled credential helpers or send user credentials to a project-provided host.
            for name in ["settings.json", "settings.local.json"] where !cwd.isEmpty {
                let project = try readSettings(URL(fileURLWithPath: cwd).appendingPathComponent(".claude/" + name))
                let env = project["env"] as? [String: String] ?? [:]
                guard project["apiKeyHelper"] == nil, project["model"] == nil,
                    !env.keys.contains(where: { $0.hasPrefix("ANTHROPIC_") || $0 == "CLAUDE_CONFIG_DIR" })
                else { throw Self.unavailable }
            }
            let env = environment.merging(settings["env"] as? [String: String] ?? [:]) { _, configured in configured }
            let fingerprint = try JSONSerialization.data(
                withJSONObject: ["settings": settings, "env": env], options: .sortedKeys)
            if !refresh, let cache, cache.fingerprint == fingerprint, cache.until > ProcessInfo.processInfo.systemUptime
            {
                return cache.entries
            }
            // Invalidate before discovery so a failed refresh cannot revive stale choices.
            cache = nil
            guard let base = URL(string: env["ANTHROPIC_BASE_URL"] ?? "https://api.anthropic.com"),
                base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
                base.scheme == "https"
                    || (base.scheme == "http" && ["127.0.0.1", "localhost", "[::1]"].contains(base.host ?? ""))
            else { throw Self.unavailable }
            let token: String
            let authorization: Bool
            if let value = env["ANTHROPIC_AUTH_TOKEN"], !value.isEmpty {
                token = value
                authorization = true
            } else if let value = env["ANTHROPIC_API_KEY"], !value.isEmpty {
                token = value
                authorization = false
            } else if let command = settings["apiKeyHelper"] as? String, !command.isEmpty {
                token = try helper(command)
                authorization = false
            } else {
                throw Self.unavailable
            }
            guard !token.isEmpty, token.utf8.count <= 8192, !token.contains("\n"), !token.contains("\r") else {
                throw Self.unavailable
            }
            let endpoint = base.appendingPathComponent("v1/models")
            var rows: [[String: Any]] = []
            var cursor: String?
            var cursors = Set<String>()
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            for _ in 0..<8 {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw Self.unavailable }
                var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
                url.queryItems = [URLQueryItem(name: "limit", value: "1000")]
                if let cursor { url.queryItems?.append(URLQueryItem(name: "after_id", value: cursor)) }
                var request = URLRequest(
                    url: url.url!, timeoutInterval: max(0.1, deadline - ProcessInfo.processInfo.systemUptime))
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.setValue(
                    authorization ? "Bearer " + token : token,
                    forHTTPHeaderField: authorization ? "Authorization" : "x-api-key")
                let data = try fetch(request)
                guard data.count <= 1024 * 1024,
                    let page = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let models = page["data"] as? [[String: Any]], rows.count + models.count <= 2048
                else { throw Self.unavailable }
                rows += models
                if page["has_more"] == nil || SessionProviderReply.boolean(page["has_more"]) == false {
                    let entries = try Self.parse(rows, settings: settings, environment: env)
                    cache = (fingerprint, ProcessInfo.processInfo.systemUptime + 60, entries)
                    return entries
                }
                guard SessionProviderReply.boolean(page["has_more"]) == true,
                    let next = page["last_id"] as? String, !next.isEmpty, next.utf8.count <= 256,
                    cursors.insert(next).inserted
                else { throw Self.unavailable }
                cursor = next
            }
            throw Self.unavailable
        } catch {
            cache = nil
            // HTTP bodies and helper stderr can contain credentials; expose only a fixed localized error.
            throw Self.unavailable
        }
    }

    private func readSettings(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Self.unavailable }
        return value
    }

    static func parse(_ rows: [[String: Any]], settings: [String: Any], environment: [String: String]) throws
        -> [[String: Any]]
    {
        var ids = Set<String>()
        let models: [[String: Any]] = try rows.map { row in
            guard let id = row["id"] as? String, !id.isEmpty, id != "default", id.utf8.count <= 256,
                id.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/-]*$", options: .regularExpression) != nil,
                ids.insert(id).inserted
            else { throw unavailable }
            let display = row["display_name"] as? String
            let name =
                (display == nil || display == id || display?.isEmpty == true) ? ClaudeBridge.modelName(id) : display!
            guard name.utf8.count <= 256,
                !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw unavailable }
            // Preserve the established CLI effort controls separately from the model ID. Unknown families use their default.
            let efforts =
                id.hasPrefix("claude-opus-") || id.hasPrefix("claude-sonnet-")
                ? ["default", "low", "medium", "high"] : ["default"]
            let aliases = ["opus", "sonnet", "haiku"].filter {
                environment["ANTHROPIC_DEFAULT_" + $0.uppercased() + "_MODEL"] == id
            }
            return ["id": id, "name": name, "efforts": efforts, "defaultEffort": "default", "aliases": aliases]
        }
        guard !models.isEmpty else { throw unavailable }
        var entry = defaultEntry
        let configured = environment["ANTHROPIC_MODEL"] ?? settings["model"] as? String
        if let configured,
            let selected = models.first(where: {
                $0["id"] as? String == configured || ($0["aliases"] as? [String] ?? []).contains(configured)
            })
        {
            entry["name"] = L10n.text("provider.default_currently_0", selected["name"] as? String ?? configured)
            entry["efforts"] = selected["efforts"]
        }
        return [entry] + models
    }
}

/// Bounded, ephemeral HTTP transport. Redirects must never carry credentials to another endpoint.
private final class ClaudeModelHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()
    private var valid = false
    private var failed = false
    private let lock = NSLock()

    static func read(_ request: URLRequest) throws -> Data {
        let reader = ClaudeModelHTTP()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration, delegate: reader, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: request).resume()
        guard reader.done.wait(timeout: .now() + request.timeoutInterval) == .success else {
            throw ClaudeModelCatalog.unavailable
        }
        return try reader.lock.withLock {
            guard reader.valid, !reader.failed else { throw ClaudeModelCatalog.unavailable }
            return reader.data
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let valid = (response as? HTTPURLResponse)?.statusCode == 200 && response.expectedContentLength <= 1024 * 1024
        lock.withLock { self.valid = valid }
        completionHandler(valid ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let oversized = lock.withLock {
            if self.data.count + data.count > 1024 * 1024 {
                failed = true
                return true
            }
            self.data.append(data)
            return false
        }
        if oversized { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { failed = failed || error != nil }
        done.signal()
    }
}
