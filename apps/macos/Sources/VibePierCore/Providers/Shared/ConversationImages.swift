import Foundation

extension ConversationReply {
    /// Only rendered Markdown image links are image references. Code samples,
    /// ordinary links and network URLs do not grant local file access.
    static func localImageReferences(_ text: String) -> [String] {
        var result: [String] = []
        var fence: Character?
        var fenceLength = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, first == "`" || first == "~" {
                let count = trimmed.prefix(while: { $0 == first }).count
                if count >= 3 {
                    if fence == nil {
                        fence = first
                        fenceLength = count
                        continue
                    }
                    if fence == first, count >= fenceLength {
                        fence = nil
                        continue
                    }
                }
            }
            guard fence == nil else { continue }
            let chars = Array(line)
            var cursor = 0
            var codeTicks = 0
            while cursor < chars.count {
                if chars[cursor] == "\\" {
                    cursor += 2
                    continue
                }
                if chars[cursor] == "`" {
                    var end = cursor
                    while end < chars.count, chars[end] == "`" { end += 1 }
                    let count = end - cursor
                    if codeTicks == 0 { codeTicks = count } else if count == codeTicks { codeTicks = 0 }
                    cursor = end
                    continue
                }
                guard codeTicks == 0, cursor + 1 < chars.count, chars[cursor] == "!", chars[cursor + 1] == "[" else {
                    cursor += 1
                    continue
                }
                var end = cursor + 2
                while end < chars.count, chars[end] != "]" { end += chars[end] == "\\" ? 2 : 1 }
                guard end + 1 < chars.count, chars[end + 1] == "(" else {
                    cursor += 1
                    continue
                }
                var start = end + 2
                while start < chars.count, chars[start].isWhitespace { start += 1 }
                guard start < chars.count else { break }
                var raw = ""
                var closing = start
                if chars[start] == "<" {
                    closing = start + 1
                    while closing < chars.count, chars[closing] != ">" {
                        raw.append(chars[closing])
                        closing += 1
                    }
                    guard closing < chars.count else {
                        cursor = start
                        continue
                    }
                    closing += 1
                } else {
                    var depth = 0
                    closing = start
                    while closing < chars.count {
                        let char = chars[closing]
                        if char == "\\", closing + 1 < chars.count {
                            raw.append(chars[closing + 1])
                            closing += 2
                            continue
                        }
                        if char == "(" { depth += 1 }
                        if char == ")" {
                            if depth == 0 { break }
                            depth -= 1
                        }
                        if char.isWhitespace, depth == 0 { break }
                        raw.append(char)
                        closing += 1
                    }
                }
                var linkEnd = closing
                while linkEnd < chars.count, chars[linkEnd].isWhitespace { linkEnd += 1 }
                if linkEnd < chars.count, chars[linkEnd] == "\"" || chars[linkEnd] == "'" {
                    let quote = chars[linkEnd]
                    linkEnd += 1
                    while linkEnd < chars.count, chars[linkEnd] != quote { linkEnd += chars[linkEnd] == "\\" ? 2 : 1 }
                    if linkEnd < chars.count { linkEnd += 1 }
                    while linkEnd < chars.count, chars[linkEnd].isWhitespace { linkEnd += 1 }
                }
                if linkEnd < chars.count, chars[linkEnd] == ")", let path = localImagePath(raw), !result.contains(path)
                {
                    result.append(path)
                }
                cursor = max(cursor + 1, linkEnd + 1)
            }
        }
        return result
    }
    private static func localImagePath(_ raw: String) -> String? {
        guard !raw.isEmpty, !raw.contains("\0"), raw.utf8.count <= 4_096 else { return nil }
        let path: String
        if raw.hasPrefix("file:") {
            guard let url = URL(string: raw), url.isFileURL,
                url.host == nil || url.host == "" || url.host == "localhost"
            else { return nil }
            path = url.path
        } else {
            guard !raw.contains(":"), !raw.hasPrefix("//"), let decoded = raw.removingPercentEncoding else {
                return nil
            }
            path = decoded
        }
        let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"]
        guard extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else { return nil }
        return path
    }
    /// Direct native image blocks only; tool arguments and arbitrary nested JSON
    /// are deliberately excluded from this extraction.
    static func imageContentSources(_ blocks: [[String: Any]]) -> [String] {
        blocks.compactMap { block in
            switch block["type"] as? String {
            case "localImage": return block["path"] as? String
            case "image", "input_image", "image_url":
                if let source = block["source"] as? [String: Any], source["type"] as? String == "base64",
                    let data = source["data"] as? String,
                    (source["media_type"] as? String ?? "image/png").hasPrefix("image/")
                {
                    return "data:\(source["media_type"] as? String ?? "image/png");base64," + data
                }
                if let data = block["data"] as? String, let mime = block["mimeType"] as? String,
                    mime.hasPrefix("image/")
                {
                    return "data:\(mime);base64," + data
                }
                return block["url"] as? String ?? block["image_url"] as? String
                    ?? (block["image_url"] as? [String: Any])?["url"] as? String
            default: return nil
            }
        }
    }
    /// The bridge has already resolved an opaque image ID from this selected
    /// session, so that source is an exact conversation reference. File reads
    /// still use the same stable, race-safe validation as Markdown previews.
    static func jpeg(_ source: String, cwd: String, maxPixel: Int) throws -> Data {
        if source.hasPrefix("data:image/") {
            guard source.utf8.count <= 48 * 1024 * 1024 else {
                throw CLIError(L10n.text("session.the_source_image_is_too_large_to_preview"))
            }
            return try jpeg(source, maxPixel: maxPixel)
        }
        let path: String
        if let url = URL(string: source), url.scheme != nil {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
                throw CLIError(L10n.text("session.session_image_previews_support_local_files_only"))
            }
            path = url.path
        } else {
            guard !source.hasPrefix("//") else {
                throw CLIError(L10n.text("session.session_image_previews_support_local_files_only"))
            }
            path = source
        }
        let bytes = try SessionMarkdownFiles.readReferencedFile(
            path, cwd: cwd, referencedPaths: [path], maximumBytes: 32 * 1024 * 1024)
        return try jpeg(bytes, maxPixel: maxPixel)
    }
}
