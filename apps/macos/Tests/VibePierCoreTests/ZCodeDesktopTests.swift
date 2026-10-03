import XCTest

@testable import VibePierCore

final class ZCodeDesktopTests: XCTestCase {
    func testCreationSelectionsRequireUnchangedNativeChoicesAndBooleanFullAccessConsent() throws {
        func choice(_ id: String, signature: String = "fixture", ordinal: Int = 0) -> ZCodeDesktop.Choice {
            .init(id: id, title: id, label: id, ordinal: ordinal, signature: signature)
        }
        let previous = [
            "model": [choice("model")], "mode": [choice("build"), choice("yolo", ordinal: 1)],
            "effort": [choice("max")],
        ]
        let request: [String: Any] = ["model": "model", "mode": "build", "effort": "max"]
        XCTAssertEqual(
            try ZCodeDesktop.creationSelection(request, previous: previous, current: previous),
            ["model": "model", "mode": "build", "effort": "max"])
        XCTAssertThrowsError(try ZCodeDesktop.creationSelection(request, previous: [:], current: previous))
        var changed = previous
        changed["model"] = [choice("model", signature: "another-account")]
        XCTAssertThrowsError(try ZCodeDesktop.creationSelection(request, previous: previous, current: changed))
        changed = previous
        changed["model"] = [choice("model", ordinal: 1)]
        XCTAssertThrowsError(try ZCodeDesktop.creationSelection(request, previous: previous, current: changed))
        for consent: Any in [false, 1, "true"] {
            XCTAssertThrowsError(
                try ZCodeDesktop.creationSelection(
                    ["model": "model", "mode": "yolo", "confirmFullAccess": consent], previous: previous,
                    current: previous))
        }
        XCTAssertEqual(
            try ZCodeDesktop.creationSelection(
                ["model": "model", "mode": "yolo", "confirmFullAccess": true], previous: previous, current: previous)[
                    "mode"], "yolo")
        XCTAssertThrowsError(
            try ZCodeDesktop.creationSelection(
                ["model": "model", "mode": "build", "effort": "unknown"], previous: previous, current: previous))
    }
    func testPermissionChoicesKeepKnownSemanticsAndFullAccessConfirmation() throws {
        let ids = try ZCodeDesktop.nativeModeIDs(["计划模式", "变更前确认", "自动编辑", "完全访问"])
        XCTAssertEqual(ids, ["plan", "build", "edit", "yolo"])
        let fullAccess = ZCodeDesktop.Choice(
            id: ids[3], title: "完全访问", label: "完全访问", ordinal: 3, signature: "fixture"
        ).object
        XCTAssertEqual(fullAccess["requiresConfirmation"] as? Bool, true)
        XCTAssertNotNil(fullAccess["confirmationText"] as? String)
    }

    func testUnknownDuplicateAndEmptyPermissionMenusCannotBecomeOpaqueChoices() {
        for labels in [[], ["完全访问", "Unknown mode"], ["Full access"], ["计划模式", "计划模式"]] {
            XCTAssertThrowsError(try ZCodeDesktop.nativeModeIDs(labels), "\(labels)")
        }
    }

    func testNativeIDRequiresOriginalSessionUUID() {
        let id = "sess_0be62575-683e-421e-87b1-6f3c534f1b33"
        XCTAssertEqual(ZCodeDesktop.nativeID("\n" + id + "\n"), id)
        XCTAssertNil(ZCodeDesktop.nativeID("sess_JgT4EJ9aBO1pFg"))
        XCTAssertNil(ZCodeDesktop.nativeID("sess_not-a-native-session"))
        XCTAssertNil(ZCodeDesktop.nativeID("file:///tmp/" + id))
    }
    func testPlaceholderNewlineIsEmptyButRealWhitespaceDraftIsProtected() {
        XCTAssertTrue(ZCodeDesktop.draftIsEmpty(""))
        XCTAssertTrue(ZCodeDesktop.draftIsEmpty("\n"))
        XCTAssertTrue(ZCodeDesktop.draftIsEmpty("\r\n"))
        XCTAssertFalse(ZCodeDesktop.draftIsEmpty(" "))
        XCTAssertFalse(ZCodeDesktop.draftIsEmpty("\t"))
        XCTAssertFalse(ZCodeDesktop.draftIsEmpty("用户已有草稿\n"))
    }
    func testSubmissionRequiresNewNativeMessageAndExactBody() {
        XCTAssertTrue(
            ZCodeDesktop.confirmation(before: "msg_old", userID: "msg_new", observed: "全文\n第二行", expected: "全文\n第二行"))
        XCTAssertFalse(ZCodeDesktop.confirmation(before: "msg_old", userID: "msg_old", observed: "全文", expected: "全文"))
        XCTAssertFalse(ZCodeDesktop.confirmation(before: nil, userID: "", observed: "全文", expected: "全文"))
        XCTAssertFalse(
            ZCodeDesktop.confirmation(before: "msg_old", userID: "msg_new", observed: "其他人的内容", expected: "全文"))
    }
    func testChangedMenuOrderInvalidatesCachedOrdinalIncludingDuplicateModels() {
        let original = ["GLM-5.3", "GLM-5.3-Flash 视觉", "GLM-5.3-Flash 视觉"]
        XCTAssertEqual(ZCodeDesktop.menuSignature(original), ZCodeDesktop.menuSignature(original))
        XCTAssertNotEqual(ZCodeDesktop.menuSignature(original), ZCodeDesktop.menuSignature(Array(original.reversed())))
        XCTAssertNotEqual(ZCodeDesktop.menuSignature(original), ZCodeDesktop.menuSignature(Array(original.dropLast())))
    }
    func testNewTaskDoesNotAssumeAProviderWhenSeveralAgentsAreEnabled() {
        XCTAssertTrue(ZCodeDesktop.nativeProviderOnly(["glm"]))
        XCTAssertFalse(ZCodeDesktop.nativeProviderOnly([]))
        XCTAssertFalse(ZCodeDesktop.nativeProviderOnly(["glm", "codex"]))
        XCTAssertFalse(ZCodeDesktop.nativeProviderOnly(["claude"]))
    }
    func testNativeNavigationSearchCanHaveOnlyPlaceholderAndNoLabel() {
        XCTAssertTrue(ZCodeDesktop.navigationSearch(label: "", placeholder: "搜索操作、任务或文件"))
        XCTAssertTrue(ZCodeDesktop.navigationSearch(label: "", placeholder: "Search actions, tasks or files"))
        XCTAssertTrue(ZCodeDesktop.navigationSearch(label: "搜索操作、任务或文件", placeholder: ""))
        XCTAssertFalse(ZCodeDesktop.navigationSearch(label: "最高", placeholder: ""))
        XCTAssertFalse(ZCodeDesktop.navigationSearch(label: "", placeholder: "向 ZCode 提问，使用 @ 添加上下文"))
    }
    func testComposerPlaceholderDoesNotTreatNavigationOrProjectSearchAsDraft() {
        XCTAssertTrue(ZCodeDesktop.composerPlaceholder("提出后续修改要求"))
        XCTAssertTrue(ZCodeDesktop.composerPlaceholder("向 ZCode 提问，使用 @ 添加上下文，使用 / 选择命令或能力"))
        XCTAssertFalse(ZCodeDesktop.composerPlaceholder("搜索操作、任务或文件"))
        XCTAssertFalse(ZCodeDesktop.composerPlaceholder("搜索项目"))
        XCTAssertFalse(ZCodeDesktop.composerPlaceholder(""))
    }
    func testProjectSearchCanHaveOnlyNativePlaceholder() {
        XCTAssertTrue(ZCodeDesktop.projectSearch(label: "", placeholder: "搜索工作区"))
        XCTAssertFalse(ZCodeDesktop.projectSearch(label: "", placeholder: "搜索操作、任务或文件"))
        XCTAssertFalse(ZCodeDesktop.projectSearch(label: "", placeholder: "向 ZCode 提问"))
    }
    func testNativeEffortListNeedsFocusedMenuItemAndSelectedOption() {
        // The real effort popup remains an AXList while its composer is visible.
        XCTAssertTrue(
            ZCodeDesktop.nativePopup(role: "AXList", focusedMenuItem: true, selectedOption: true, searchField: false))
        XCTAssertFalse(
            ZCodeDesktop.nativePopup(role: "AXList", focusedMenuItem: false, selectedOption: true, searchField: false))
        XCTAssertFalse(
            ZCodeDesktop.nativePopup(role: "AXList", focusedMenuItem: true, selectedOption: false, searchField: false))
        XCTAssertFalse(
            ZCodeDesktop.nativePopup(role: "AXList", focusedMenuItem: false, selectedOption: false, searchField: true))
    }
    func testNativeMenuExcludesStalePopupWithoutFocusOrSearch() {
        XCTAssertTrue(
            ZCodeDesktop.nativePopup(role: "AXMenu", focusedMenuItem: true, selectedOption: false, searchField: false))
        XCTAssertTrue(
            ZCodeDesktop.nativePopup(role: "AXMenu", focusedMenuItem: false, selectedOption: false, searchField: true))
        XCTAssertTrue(
            ZCodeDesktop.nativePopup(
                role: "AXMenu", focusedMenuItem: false, selectedOption: false, searchField: false, focusedMenu: true))
        XCTAssertFalse(
            ZCodeDesktop.nativePopup(role: "AXMenu", focusedMenuItem: false, selectedOption: true, searchField: false))
        XCTAssertFalse(
            ZCodeDesktop.nativePopup(role: "AXOutline", focusedMenuItem: true, selectedOption: true, searchField: false)
        )
        XCTAssertFalse(
            ZCodeDesktop.nativePopup(
                role: "AXList", focusedMenuItem: false, selectedOption: true, searchField: false, focusedMenu: true))
    }
    func testModelAndModeOptionsExcludeProviderAndManagementRowsWithDefaultSelected() {
        XCTAssertTrue(
            ZCodeDesktop.selectableOption(kind: "model", popupRole: "AXMenu", hasValue: true, hasSelected: true))
        XCTAssertTrue(
            ZCodeDesktop.selectableOption(kind: "mode", popupRole: "AXMenu", hasValue: true, hasSelected: false))
        XCTAssertFalse(
            ZCodeDesktop.selectableOption(kind: "model", popupRole: "AXMenu", hasValue: false, hasSelected: true))
        XCTAssertFalse(
            ZCodeDesktop.selectableOption(kind: "mode", popupRole: "AXMenu", hasValue: false, hasSelected: true))
    }
    func testOnlyNativeEffortListUsesSelectedAttributeAsChoiceAuthority() {
        XCTAssertTrue(
            ZCodeDesktop.selectableOption(kind: "effort", popupRole: "AXList", hasValue: false, hasSelected: true))
        XCTAssertFalse(
            ZCodeDesktop.selectableOption(kind: "effort", popupRole: "AXList", hasValue: true, hasSelected: false))
        XCTAssertFalse(
            ZCodeDesktop.selectableOption(kind: "effort", popupRole: "AXMenu", hasValue: false, hasSelected: true))
        XCTAssertTrue(
            ZCodeDesktop.selectableOption(kind: "effort", popupRole: "AXMenu", hasValue: true, hasSelected: false))
    }
    private func workspace(_ path: String, purpose: String = "project") -> [String: Any] {
        ["kind": "local", "workspacePath": path, "workspacePurpose": purpose]
    }
    func testNativeProjectBindingUsesFullQueryAndFirstFiveTabOrder() {
        let cwd = "/Users/demo/Documents/code"
        let tabs = [
            workspace(cwd + "/vibepier"), workspace(cwd), workspace(cwd + "/ble"), workspace(cwd + "/NiceTab"),
            workspace(cwd + "1/unrelated-workspace"), workspace(cwd + "/example-project"),
            workspace("/Users/demo/Downloads/english/code"),
            workspace(cwd + "/draft", purpose: "conversation"),
        ]
        let binding = ZCodeDesktop.projectBinding(cwd: cwd, workspaces: tabs)
        XCTAssertEqual(binding?.query, cwd)
        XCTAssertEqual(binding?.labels, ["vibepier", "code", "ble", "NiceTab", "unrelated-workspace"])
        XCTAssertEqual(binding?.paths, Array(tabs.prefix(5)).compactMap { $0["workspacePath"] as? String })
        XCTAssertEqual(binding?.targetIndex, 1)
    }
    func testProjectBindingRefusesFilteredDuplicateNamesOrDuplicateNativePaths() {
        let cwd = "/tmp/code"
        XCTAssertNil(ZCodeDesktop.projectBinding(cwd: cwd, workspaces: [workspace(cwd), workspace(cwd + "/code")]))
        XCTAssertNil(ZCodeDesktop.projectBinding(cwd: cwd, workspaces: [workspace(cwd), workspace(cwd)]))
        XCTAssertNil(ZCodeDesktop.projectBinding(cwd: cwd, workspaces: [workspace(cwd + "/child")]))
        XCTAssertNil(ZCodeDesktop.projectBinding(cwd: cwd, workspaces: [workspace(cwd, purpose: "conversation")]))
    }
    func testProjectBindingRefusesTargetBeyondNativeFiveResultLimit() {
        let cwd = "/tmp/code"
        let children = (1...5).map { workspace(cwd + "/child\($0)") }
        XCTAssertNil(ZCodeDesktop.projectBinding(cwd: cwd, workspaces: children + [workspace(cwd)]))
    }
    func testProjectBindingRefusesRemoteIdentityInVisibleMapping() {
        let cwd = "/tmp/code"
        var remote = workspace(cwd + "/remote")
        remote["workspaceIdentity"] = "ssh:example"
        XCTAssertNil(ZCodeDesktop.projectBinding(cwd: cwd, workspaces: [workspace(cwd), remote]))
    }
    func testProjectResultsRequireFreshQueryAndStableCompleteNativeOrder() {
        var stable = ZCodeDesktop.StableResults()
        let query = "/tmp/code"
        let expected = ["vibepier", "code", "ble"]
        XCTAssertFalse(
            stable.observe(query: "weix", expectedQuery: query, labels: expected, expectedLabels: expected, at: 0))
        XCTAssertFalse(
            stable.observe(query: query, expectedQuery: query, labels: expected, expectedLabels: expected, at: 1))
        XCTAssertFalse(
            stable.observe(query: query, expectedQuery: query, labels: expected, expectedLabels: expected, at: 1.4))
        XCTAssertTrue(
            stable.observe(query: query, expectedQuery: query, labels: expected, expectedLabels: expected, at: 1.5))
        XCTAssertFalse(
            stable.observe(
                query: query, expectedQuery: query, labels: ["code", "vibepier", "ble"], expectedLabels: expected, at: 2
            ))
        XCTAssertFalse(
            stable.observe(query: query, expectedQuery: query, labels: expected, expectedLabels: expected, at: 2.1))
        XCTAssertTrue(
            stable.observe(query: query, expectedQuery: query, labels: expected, expectedLabels: expected, at: 2.7))
        XCTAssertFalse(
            stable.observe(query: "weix", expectedQuery: query, labels: expected, expectedLabels: expected, at: 3))
        XCTAssertFalse(
            stable.observe(query: query, expectedQuery: query, labels: expected, expectedLabels: expected, at: 4))
        stable.reset()  // A vanished/replaced AX field also breaks continuity.
        XCTAssertFalse(
            stable.observe(query: query, expectedQuery: query, labels: expected, expectedLabels: expected, at: 5))
        XCTAssertTrue(
            stable.observe(query: query, expectedQuery: query, labels: expected, expectedLabels: expected, at: 5.5))
    }
}
