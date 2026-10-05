import Foundation
import ImageIO

/// Shapes a turn the way Claude Code and Codex desktop show it: the person's message, then one reply holding every
/// step in order — text, thinking, commands with output, file edits with diffs, other tool calls and notices.
/// Rows carry full bodies until `bounded` trims them for the phone; `fullText` serves the rest on demand.
enum ConversationReply {
    /// `kind`: text, thinking, plan, command, file, tool, notice. `status`: running, completed, failed, declined or empty.
    struct Part {
        var id: String
        var kind: String
        var title = ""
        var status = ""
        var text = ""
        var extra: [String: Any] = [:]
        var value: [String: Any] {
            var row = extra
            row["id"] = id
            row["kind"] = kind
            row["title"] = title
            row["status"] = status
            row["text"] = text
            return row
        }
    }
    /// Collects one turn's rows; a user message closes the reply before it, so each message gets its own reply.
    struct Builder {
        private(set) var rows: [[String: Any]] = []
        private var parts: [Part] = []
        private var replyID = ""
        mutating func user(_ id: String, text: String, extra: [String: Any] = [:]) {
            flush()
            var row = extra
            row["id"] = id
            row["role"] = "user"
            row["text"] = text
            let sources = (row[imageKey] as? [String] ?? []) + localImageReferences(text)
            if !sources.isEmpty { row[imageKey] = sources }
            rows.append(row)
            replyID = "reply-" + id
        }
        mutating func add(_ input: Part) {
            var part = input
            if part.kind == "text" {
                let sources = (part.extra[imageKey] as? [String] ?? []) + localImageReferences(part.text)
                if !sources.isEmpty { part.extra[imageKey] = sources }
            }
            if replyID.isEmpty { replyID = "reply-" + part.id }
            // Streamed text arrives as consecutive blocks; the desktop shows them as one paragraph run.
            if part.kind == "text", let last = parts.last, last.kind == "text" {
                parts[parts.count - 1].text += "\n\n" + part.text
                let sources = (last.extra[imageKey] as? [String] ?? []) + (part.extra[imageKey] as? [String] ?? [])
                if !sources.isEmpty { parts[parts.count - 1].extra[imageKey] = sources }
                return
            }
            parts.append(part)
        }
        mutating func update(_ id: String, _ change: (inout Part) -> Void) {
            if let index = parts.lastIndex(where: { $0.id == id }) { change(&parts[index]) }
        }
        /// Steps still waiting when the turn was stopped never finish.
        mutating func settleRunning(_ status: String) {
            for index in parts.indices where parts[index].status == "running" { parts[index].status = status }
        }
        mutating func finish(status: String = "") -> [[String: Any]] {
            flush(status: status)
            return rows
        }
        private mutating func flush(status: String = "") {
            guard !parts.isEmpty else { return }
            let text = parts.filter { $0.kind == "text" }.map(\.text).joined(separator: "\n\n")
            rows.append([
                "id": replyID, "role": "assistant", "text": text, "status": status, "parts": parts.map(\.value),
            ])
            parts = []
            replyID = ""
        }
    }

    static let prose: Set<String> = ["text", "plan"]
    /// A conversation opens on its newest turns; scrolling up asks for earlier ones a batch at a time.
    static let recentTurns = 1
    static let olderTurns = 3
    static let recentParts = 8
    /// A semantic grouping key contains no arguments, filenames or output.
    /// The phone still checks adjacency and gaps before folding a run of steps.
    static func toolGrouping(_ name: String, namespace: String? = nil) -> [String: Any] {
        guard !name.isEmpty else { return [:] }
        if namespace == nil, name.hasPrefix("mcp__") {
            let components = String(name.dropFirst(5)).components(separatedBy: "__")
            if components.count >= 2 {
                return toolGrouping(components.dropFirst().joined(separator: "__"), namespace: components[0])
            }
        }
        let operation: String
        if let namespace {
            operation = "tool:" + CodexConversation.fingerprint(["namespace": namespace, "name": name])
        } else {
            switch name {
            case "Bash": operation = "command"
            case "Edit", "MultiEdit", "Write", "NotebookEdit": operation = "file-edit"
            case "Read", "NotebookRead": operation = "file-read"
            case "Grep", "Glob": operation = "file-search"
            case "WebSearch": operation = "web-search"
            case "WebFetch": operation = "web-fetch"
            case "Task", "Agent": operation = "agent"
            case "AskUserQuestion", "ExitPlanMode": operation = "approval"
            case "EnterPlanMode", "TodoRead", "TodoWrite": operation = "plan"
            default: operation = "tool:" + CodexConversation.fingerprint(["namespace": "", "name": name])
            }
        }
        return ["groupType": operation, "toolName": namespace.map { $0.isEmpty ? name : $0 + " · " + name } ?? name]
    }
    /// A live subscription confirms capabilities every time; identical content need not travel again.
    static func versioned(_ page: [String: Any]) -> [String: Any] {
        var value = page
        let content = page.filter {
            !["cacheVersion", "revision", "viewVersion", "event", "baseRevision", "canSend", "ok"].contains($0.key)
        }
        value["cacheVersion"] = CodexConversation.fingerprint(content)
        return value
    }
    static func conditional(_ page: [String: Any], known: String?) -> [String: Any] {
        var value = versioned(page)
        if let known, !known.isEmpty, known == value["cacheVersion"] as? String {
            value.removeValue(forKey: "messages")
            value["unchanged"] = true
        }
        return value
    }
    /// Up to `olderTurns` turns before the one holding message `id` (the oldest the phone shows), and whether any remain.
    static func older(_ turns: [[[String: Any]]], before id: String) -> (rows: [[String: Any]], start: Int)? {
        guard let index = turns.firstIndex(where: { $0.contains { $0["id"] as? String == id } }) else { return nil }
        let start = max(0, index - olderTurns)
        return (preview(turns[start..<index].flatMap { $0 }), start)
    }
    /// Only answer previews ride with a timeline page. Hundreds of tool steps are fetched separately on demand.
    static func preview(_ rows: [[String: Any]]) -> [[String: Any]] {
        let light = rows.map { row -> [String: Any] in
            var row = row
            if let parts = row.removeValue(forKey: "parts") as? [[String: Any]], !parts.isEmpty {
                row["partsDeferred"] = true
                row["partCount"] = parts.count
                let process = parts.filter { $0["kind"] as? String != "text" }
                row["processCount"] = process.count
                row["partsVersion"] = CodexConversation.fingerprint([
                    "parts": process.map { part -> [String: Any] in
                        partHeader(part, withBodyVersion: false)
                    }
                ])
                let start = max(0, parts.count - recentParts)
                row["sequenceStart"] = start
                row["parts"] = sequenceParts(parts, start: start, end: parts.count)
            }
            return row
        }
        return bounded(light, budget: 12_000).map { row in
            var row = row
            if let parts = row.removeValue(forKey: "parts") { row["sequence"] = parts }
            return row
        }
    }
    /// A small page of processing steps inside one reply; full bodies still use the existing message endpoint.
    static func partPage(
        _ rows: [[String: Any]], id: String, offset: Int, headersOnly: Bool = false, sequence: Bool = false,
        before: Int? = nil
    ) -> [String: Any]? {
        guard let row = rows.first(where: { $0["id"] as? String == id }), let all = row["parts"] as? [[String: Any]]
        else { return nil }
        if sequence {
            let start = max(0, min(offset, all.count))
            let end = min(start + recentParts, max(start, min(before ?? all.count, all.count)))
            let projected = bounded(
                [["id": id, "text": "", "parts": sequenceParts(all, start: start, end: end)]], budget: 12_000)
            return [
                "parts": projected.first?["parts"] ?? [], "partCount": all.count, "start": start,
                "nextOffset": end < all.count ? end : -1,
            ]
        }
        let parts = headersOnly ? all.filter { $0["kind"] as? String != "text" } : all
        let start = max(0, min(offset, parts.count))
        let end = min(start + 8, parts.count)
        if headersOnly {
            return [
                "parts": parts[start..<end].map { partHeader($0) }, "nextOffset": end < parts.count ? end : -1,
                "partCount": parts.count,
            ]
        }
        let projected = bounded([["id": id, "text": "", "parts": Array(parts[start..<end])]], budget: 12_000)
        return [
            "parts": projected.first?["parts"] ?? [], "nextOffset": end < parts.count ? end : -1,
            "partCount": parts.count,
        ]
    }
    /// Preserve the desktop's interleaving of paragraphs and individual steps; tool bodies stay on the Mac.
    private static func sequenceParts(_ parts: [[String: Any]], start: Int, end: Int) -> [[String: Any]] {
        (start..<end).map { index in
            let part = parts[index]
            var value = partHeader(part)
            value["index"] = index
            if prose.contains(part["kind"] as? String ?? "") {
                value["text"] = part["text"] as? String ?? ""
            } else {
                value["bodyDeferred"] = true
            }
            return value
        }
    }
    /// A header has no output, thinking text or diff; each body is requested only after its row opens.
    private static func partHeader(_ part: [String: Any], withBodyVersion: Bool = true) -> [String: Any] {
        var header = part.filter {
            ["id", "kind", "status", "exitCode", "durationMs", "added", "removed"].contains($0.key)
        }
        for key in ["title", "cwd", "description", "groupType", "toolName"] {
            if let text = part[key] as? String {
                if key == "toolName" {
                    // Eight long names must leave room for IDs, grouping hashes
                    // and titles even before the page trims its prose.
                    var name = ""
                    var bytes = 0
                    for character in text.prefix(128) {
                        let width = String(character).utf8.count
                        guard bytes + width <= 512 else { break }
                        name.append(character)
                        bytes += width
                    }
                    header[key] = name
                } else {
                    header[key] = String(text.prefix(key == "title" ? 400 : 200))
                }
            }
        }
        let count = (part[imageKey] as? [String])?.count ?? (part["images"] as? [[String: Any]])?.count ?? 0
        if count > 0 { header["images"] = (0..<min(count, 12)).map { ["id": "\(part["id"] as? String ?? "")#\($0)"] } }
        if withBodyVersion {
            let text = part["text"] as? String ?? ""
            let status = part["status"] as? String ?? ""
            header["bodyVersion"] =
                status == "running" && !prose.contains(part["kind"] as? String ?? "")
                ? "running" : CodexConversation.dataHash(Data(text.utf8)) + "|" + status
        }
        return header
    }
    /// What one page may weigh once serialized. The transport refuses replies over 300 KB, and a long session can hold
    /// hundreds of commands whose titles, folders and ids alone pass that, so the budget is measured, not estimated.
    static let pageBudget = 160_000
    /// Trims every body so a page fits `pageBudget` whatever the turns hold; prose gets the larger share. Each pass that
    /// is still too heavy halves bodies and titles — every step stays, and the rest loads on demand.
    static func bounded(_ rows: [[String: Any]], budget: Int = pageBudget) -> [[String: Any]] {
        let parts = rows.flatMap { $0["parts"] as? [[String: Any]] ?? [] }
        let proseCount = rows.count + parts.filter { prose.contains($0["kind"] as? String ?? "") }.count
        let detailCount = parts.count - parts.filter { prose.contains($0["kind"] as? String ?? "") }.count
        let proseLimit = min(4000, max(1, 120_000 / max(1, proseCount) / 4))
        let detailLimit = min(1500, max(80, 60_000 / max(1, detailCount)))
        func trim(_ item: [String: Any], _ limit: Int, _ titleLimit: Int) -> [String: Any] {
            var value = item
            let text = item["text"] as? String ?? ""
            // Hundreds of steps: their folder and note go before the steps themselves would have to.
            if titleLimit < 100 {
                value.removeValue(forKey: "cwd")
                value.removeValue(forKey: "description")
            }
            value["text"] = String(text.prefix(limit))
            value["hasMore"] = text.count > limit
            value["nextOffset"] = min(text.count, limit)
            for key in ["title", "description"] {
                if let line = item[key] as? String, line.count > titleLimit {
                    value[key] = String(line.prefix(titleLimit)) + "…"
                }
            }
            if let sources = value.removeValue(forKey: imageKey) as? [String], !sources.isEmpty {
                let owner = item["id"] as? String ?? ""
                value["images"] = sources.indices.map { ["id": "\(owner)#\($0)"] }
            }
            return value
        }
        var scale = 1
        while true {
            let titleLimit = max(40, 400 / scale)
            let out = rows.map { row in
                var value = trim(row, max(200, proseLimit / scale), titleLimit)
                if let items = row["parts"] as? [[String: Any]] {
                    value["parts"] = items.map {
                        prose.contains($0["kind"] as? String ?? "")
                            ? trim($0, max(200, proseLimit / scale), titleLimit)
                            : trim($0, detailLimit / scale, titleLimit)
                    }
                }
                return value
            }
            if scale >= 64 || (try? JSONSerialization.data(withJSONObject: out).count).map({ $0 <= budget }) ?? true {
                return out
            }
            scale *= 2
        }
    }
    /// The untrimmed body of a message or of one step inside a reply.
    static func fullText(_ rows: [[String: Any]], id: String) -> String? {
        for row in rows {
            if row["id"] as? String == id { return row["text"] as? String }
            if let part = (row["parts"] as? [[String: Any]])?.first(where: { $0["id"] as? String == id }) {
                return part["text"] as? String
            }
        }
        return nil
    }
    static func partDetails(_ rows: [[String: Any]], id: String) -> [String: Any]? {
        guard
            let part = rows.lazy.compactMap({ ($0["parts"] as? [[String: Any]])?.first { $0["id"] as? String == id } })
                .first
        else { return nil }
        var details = partHeader(part)
        for key in ["title", "cwd", "description"] {
            if let text = part[key] as? String { details[key] = String(text.prefix(key == "title" ? 12_000 : 1000)) }
        }
        return details
    }
    /// Images never ride in a page: rows keep each source (a data URL or a Mac file path) and the phone gets ids to fetch.
    static let imageKey = "imageSources"
    static func image(_ rows: [[String: Any]], id: String) -> String? {
        guard let mark = id.range(of: "#", options: .backwards), let index = Int(id[mark.upperBound...]) else {
            return nil
        }
        let owner = String(id[..<mark.lowerBound])
        for row in rows {
            guard
                let item = ([row] + (row["parts"] as? [[String: Any]] ?? [])).first(where: {
                    $0["id"] as? String == owner
                })
            else { continue }
            let sources = item[imageKey] as? [String] ?? []
            return sources.indices.contains(index) ? sources[index] : nil
        }
        return nil
    }
    /// A conversation image as a phone-sized JPEG on white, small enough for one Wi-Fi or Bluetooth reply.
    static func jpeg(_ source: String, maxPixel: Int) throws -> Data {
        if source.hasPrefix("data:"), let comma = source.firstIndex(of: ","),
            let data = Data(
                base64Encoded: String(source[source.index(after: comma)...]), options: .ignoreUnknownCharacters)
        {
            return try jpeg(data, maxPixel: maxPixel)
        } else if source.hasPrefix("/") {
            return try jpeg(Data(contentsOf: URL(fileURLWithPath: source)), maxPixel: maxPixel)
        }
        throw CLIError(L10n.text("session.the_image_no_longer_exists_or_cannot_be_read"))
    }
    static func jpeg(_ data: Data, maxPixel: Int, maximumBytes: Int = 200_000) throws -> Data {
        guard data.count <= 32 * 1024 * 1024 else {
            throw CLIError(L10n.text("session.the_source_image_is_too_large_to_preview"))
        }
        let image = CGImageSourceCreateWithData(data as CFData, nil)
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(64, min(maxPixel, 2048)),
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary
        guard let image, let thumb = CGImageSourceCreateThumbnailAtIndex(image, 0, options),
            let context = CGContext(
                data: nil, width: thumb.width, height: thumb.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CLIError(L10n.text("session.the_image_no_longer_exists_or_cannot_be_read")) }
        let rect = CGRect(x: 0, y: 0, width: thumb.width, height: thumb.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(thumb, in: rect)
        guard let flat = context.makeImage() else {
            throw CLIError(L10n.text("session.the_image_no_longer_exists_or_cannot_be_read"))
        }
        for quality in maximumBytes > 200_000 ? [0.9, 0.75, 0.55] : [0.75, 0.55, 0.35] {
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
                break
            }
            CGImageDestinationAddImage(
                destination, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), out.length <= maximumBytes { return out as Data }
        }
        throw CLIError(L10n.text("session.the_image_is_too_large_to_transfer_to_the_phone"))
    }
    static func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else {
            return value as? String ?? String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }
    /// Added and removed line counts of a unified diff, ignoring its file headers.
    static func lineCounts(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                added += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                removed += 1
            }
        }
        return (added, removed)
    }
    /// A replacement shown as removed and added lines, the way the desktop renders an edit.
    static func replacement(_ old: String, _ new: String) -> String {
        func lines(_ text: String, _ mark: String) -> [String] {
            text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map { mark + $0 }
        }
        return (lines(old, "-") + lines(new, "+")).joined(separator: "\n")
    }
}
