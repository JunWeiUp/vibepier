import XCTest

@testable import VibeLocalization

final class LocalizationTests: XCTestCase {
    func testBothLanguagesAndNumberedArguments() {
        XCTAssertEqual(L10n.render("common.close", language: .english), "Close")
        XCTAssertEqual(L10n.render("common.close", language: .simplifiedChinese), "关闭")
        XCTAssertEqual(
            L10n.render("task.counts", arguments: ["2", "3"], language: .english), "Running: 2 · Unviewed: 3")
        XCTAssertEqual(L10n.render("task.counts", arguments: ["2", "3"], language: .simplifiedChinese), "2 运行 · 3 未查看")
    }

    func testArgumentsAreNotReinterpretedAsSlotsOrFormatSpecifiers() {
        XCTAssertEqual(
            L10n.render("task.counts", arguments: ["{1} %s \\(raw)", "100%"], language: .english),
            "Running: {1} %s \\(raw) · Unviewed: 100%")
        XCTAssertEqual(L10n.render("missing.key", language: .english), "missing.key")
    }

    func testAppAndCLIRespectTheirOwnLanguageSources() {
        XCTAssertEqual(
            L10n.resolveLanguage(preferences: ["zh-Hans-CN"], environment: ["LANG": "en_US.UTF-8"], application: true),
            .simplifiedChinese)
        XCTAssertEqual(
            L10n.resolveLanguage(
                preferences: ["zh-Hans"], environment: ["LC_ALL": "C", "LANG": "zh_CN.UTF-8"], application: false),
            .english)
        XCTAssertEqual(
            L10n.resolveLanguage(preferences: ["en"], environment: ["LANG": "zh_CN.UTF-8"], application: false),
            .simplifiedChinese)
        XCTAssertEqual(
            L10n.resolveLanguage(
                preferences: ["en"], environment: ["VIBEPIER_LANGUAGE": "zh-Hans", "LC_ALL": "C"], application: false),
            .simplifiedChinese)
        XCTAssertEqual(L10n.resolveLanguage(preferences: ["fr-FR"], environment: [:], application: true), .english)
        XCTAssertEqual(L10n.resolveLanguage(preferences: ["zh-Hant-TW"], environment: [:], application: true), .english)
    }
}
