import AppKit
import SwiftUI
import XCTest

@testable import VibePierApp

/// Opt-in visual artifacts. These are labelled synthetic fixtures, never screenshots of the user's menu bar.
@MainActor
final class TaskIconPreviewTests: XCTestCase {
    func testExportTaskIconLightAndDarkFixturesWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VIBEPIER_TASK_ICON_PREVIEW_DIR"],
            !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw XCTSkip("Set VIBEPIER_TASK_ICON_PREVIEW_DIR to export the labelled 4x task-icon fixtures")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = try templateBase()
        let light = TaskIconPreviewSheet(base: base, scheme: .light).environment(\.colorScheme, .light)
        let dark = TaskIconPreviewSheet(base: base, scheme: .dark).environment(\.colorScheme, .dark)
        try save(
            light, to: directory.appendingPathComponent("task-icon-fixtures-light.png"),
            width: TaskIconPreviewSheet.width)
        try save(
            dark, to: directory.appendingPathComponent("task-icon-fixtures-dark.png"), width: TaskIconPreviewSheet.width
        )
        try save(
            HStack(spacing: 0) {
                light
                dark
            }, to: directory.appendingPathComponent("task-icon-fixtures-comparison.png"),
            width: TaskIconPreviewSheet.width * 2)
        try """
        SYNTHETIC VISUAL FIXTURES — NOT LIVE SCREENSHOTS
        Rendered with the real TaskActivityMenuIcon at 4x pixel scale using SwiftUI ImageRenderer.
        The base is the production 18pt VibePier brand template from MenuBarIcon.
        Rows: no tasks; one running; three unread completions; one running + three unread;
        one running + 25 unread; one running + 257 unread.
        light/dark are standalone; comparison places them side by side.
        No production state, session, device, network, or application preferences are read or changed.
        """.write(to: directory.appendingPathComponent("task-icon-fixtures.txt"), atomically: true, encoding: .utf8)
    }

    private func save<Content: View>(_ content: Content, to file: URL, width: CGFloat) throws {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 4
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(width: width, height: TaskIconPreviewSheet.height)
        let rendered = renderer.cgImage
        let image = try XCTUnwrap(rendered, "SwiftUI could not render the task-icon fixture")
        XCTAssertEqual(image.width, Int(width * 4))
        XCTAssertEqual(image.height, Int(TaskIconPreviewSheet.height * 4))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: file, options: .atomic)
    }

    private func templateBase() throws -> NSImage {
        MenuBarIcon.image(symbol: "waveform")
    }

}

private struct TaskIconPreviewSheet: View {
    static let width: CGFloat = 470
    static let height: CGFloat = 380
    struct Fixture: Identifiable {
        let id: String
        let title: String
        let running: Int
        let unread: Int
        var activity: TaskActivityJSON { .init(runningCount: running, unreadCount: unread, sessions: []) }
        var layout: TaskIndicatorLayout { .init(runningCount: running, unreadCount: unread) }
    }
    private let fixtures = [
        Fixture(id: "empty", title: "无任务", running: 0, unread: 0),
        Fixture(id: "running", title: "1 个运行任务", running: 1, unread: 0),
        Fixture(id: "unread", title: "3 个未查看完成", running: 0, unread: 3),
        Fixture(id: "mixed", title: "运行 + 3 个完成", running: 1, unread: 3),
        Fixture(id: "dense", title: "运行 + 25 个完成", running: 1, unread: 25),
        Fixture(id: "large", title: "运行 + 257 个完成", running: 1, unread: 257),
    ]
    let base: NSImage
    let scheme: ColorScheme
    private var dark: Bool { scheme == .dark }

    init(base: NSImage, scheme: ColorScheme) {
        self.base = base
        self.scheme = scheme
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("TaskActivityMenuIcon · FIXTURE").font(.system(size: 16, weight: .semibold))
                Text("\(dark ? "深色" : "浅色") · 非实机截图 · 4× 像素 · 原始图标高度 18pt")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(fixtures) { fixture in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fixture.title).font(.system(size: 12, weight: .medium))
                        Text("\(fixture.running) 运行 · \(fixture.unread) 未查看 · \(fixture.layout.width.formatted())pt")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(width: 185, alignment: .leading)
                    TaskActivityMenuIcon(base: base, activity: fixture.activity)
                        .padding(.leading, 10)
                        .frame(width: 205, height: 24, alignment: .leading)
                        .background(dark ? Color(white: 0.23) : Color(white: 0.90))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .frame(height: 40)
            }
            Text("静态测试数据；未读取真实会话、设备或网络。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .background(dark ? Color(white: 0.14) : Color(white: 0.98))
    }
}
