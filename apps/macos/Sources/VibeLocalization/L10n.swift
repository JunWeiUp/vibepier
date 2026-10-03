import Foundation

/// A compiled catalog keeps the CLI self-contained while respecting the application's language.
public enum L10n {
    public enum Language: String, Sendable {
        case english = "en"
        case simplifiedChinese = "zh-Hans"
    }

    public static let language = resolveLanguage(
        preferences: Locale.preferredLanguages,
        environment: ProcessInfo.processInfo.environment,
        application: Bundle.main.bundleIdentifier == "io.github.junweiup.vibepier")

    public static func text(_ key: String, _ arguments: Any...) -> String {
        render(key, arguments: arguments.map { String(describing: $0) }, language: language)
    }

    private static let slots = try? NSRegularExpression(pattern: #"\{([0-9]+)\}"#)

    /// Numbered slots allow translated word order without interpreting user content as a format string.
    public static func render(_ key: String, arguments: [String] = [], language: Language) -> String {
        guard let entry = LocalizationCatalog.entries[key] else { return key }
        let template = entry[language == .english ? 0 : 1]
        guard let expression = slots else { return template }
        let matches = expression.matches(in: template, range: NSRange(template.startIndex..., in: template))
        let result = NSMutableString(string: template)
        for match in matches.reversed() {
            guard let range = Range(match.range(at: 1), in: template),
                let index = Int(template[range]), arguments.indices.contains(index)
            else { return template }
            result.replaceCharacters(in: match.range, with: arguments[index])
        }
        return result as String
    }

    static func resolveLanguage(preferences: [String], environment: [String: String], application: Bool) -> Language {
        if let forced = environment["VIBEPIER_LANGUAGE"], !forced.isEmpty { return resolve(forced) }
        if !application {
            for name in ["LC_ALL", "LC_MESSAGES", "LANG"] {
                if let locale = environment[name], !locale.isEmpty { return resolve(locale) }
            }
        }
        return preferences.first.map(resolve) ?? .english
    }

    private static func resolve(_ value: String) -> Language {
        let tag =
            value.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: ".").first.map(String.init)
            ?? ""
        return tag == "zh" || tag == "zh-cn" || tag == "zh-sg" || tag.hasPrefix("zh-hans")
            ? .simplifiedChinese : .english
    }
}
