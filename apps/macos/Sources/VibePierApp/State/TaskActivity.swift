import Foundation
import SwiftUI
import VibePierCore

struct TaskSessionKey: Hashable {
    let provider: String
    let id: String
}

/// A local Driver snapshot; task details are neither fetched nor opened while drawing the menu bar.
struct TaskActivityJSON: Decodable, Equatable {
    struct Session: Decodable, Equatable {
        let id: String
        let provider: String
        let title: String
        let isRunning: Bool
        let isUnread: Bool

        var key: TaskSessionKey { TaskSessionKey(provider: provider, id: id) }
        var providerLabel: String {
            switch provider {
            case "codex": return "Codex"
            case "claude": return "Claude"
            case "zcode": return "ZCode"
            default: return provider
            }
        }
        var displayTitle: String {
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.text("mac.untitled_session") : title
        }
        var statusLabel: String {
            isRunning
                ? (isUnread ? L10n.text("mac.running_with_an_unviewed_completion") : L10n.text("mac.running"))
                : (isUnread ? L10n.text("mac.completed_not_viewed") : L10n.text("mac.viewed"))
        }
    }

    let runningCount: Int
    let unreadCount: Int
    let sessions: [Session]
    static let empty = TaskActivityJSON(runningCount: 0, unreadCount: 0, sessions: [])

    /// Keep the Driver's order within each group and distinguish the same ID in different providers.
    var orderedSessions: [Session] {
        sessions.filter(\.isRunning) + sessions.filter { !$0.isRunning && $0.isUnread }
    }
}

/// Keep every unread task visible: three ordinary rows, or six denser rows above 24 dots.
struct TaskIndicatorLayout: Equatable {
    static let canvasSize: CGFloat = 18
    static let runningSlotSize: CGFloat = 5
    static let spacing: CGFloat = 1
    static let gap: CGFloat = 3
    let hasRunning: Bool
    let unreadCount: Int
    var markerCount: Int { unreadCount + (hasRunning ? 1 : 0) }
    var isDense: Bool { unreadCount > 24 }
    private var maximumRows: Int { isDense ? 6 : 3 }
    private var dotSize: CGFloat { isDense ? 2 : 3.5 }
    var rowCount: Int { min(maximumRows, unreadCount) }
    var columnCount: Int { unreadCount == 0 ? 0 : (unreadCount - 1) / maximumRows + 1 }
    var width: CGFloat {
        guard markerCount > 0 else { return Self.canvasSize }
        let runningWidth = hasRunning ? Self.runningSlotSize : 0
        let dotsWidth = CGFloat(columnCount) * dotSize + CGFloat(max(0, columnCount - 1)) * Self.spacing
        let separator = hasRunning && unreadCount > 0 ? Self.gap : 0
        return Self.canvasSize + Self.gap + runningWidth + separator + dotsWidth
    }

    init(runningCount: Int, unreadCount: Int) {
        hasRunning = runningCount > 0
        self.unreadCount = max(0, unreadCount)
    }
    func isRunningMarker(_ index: Int) -> Bool { hasRunning && index == 0 }
    func markerSize(_ index: Int) -> CGFloat { isRunningMarker(index) ? Self.runningSlotSize : dotSize }
    func position(_ index: Int) -> CGPoint {
        if isRunningMarker(index) {
            return CGPoint(x: Self.canvasSize + Self.gap + Self.runningSlotSize / 2, y: Self.canvasSize / 2)
        }
        let dot = index - (hasRunning ? 1 : 0)
        let column = dot / maximumRows
        let row = dot % maximumRows
        let height = CGFloat(rowCount) * dotSize + CGFloat(max(0, rowCount - 1)) * Self.spacing
        let start = Self.canvasSize + Self.gap + (hasRunning ? Self.runningSlotSize + Self.gap : 0)
        return CGPoint(
            x: start + dotSize / 2 + CGFloat(column) * (dotSize + Self.spacing),
            y: (Self.canvasSize - height) / 2 + dotSize / 2 + CGFloat(row) * (dotSize + Self.spacing))
    }
}

struct TaskActivityMenuIcon: View {
    let base: NSImage
    let activity: TaskActivityJSON

    private var layout: TaskIndicatorLayout {
        TaskIndicatorLayout(runningCount: activity.runningCount, unreadCount: activity.unreadCount)
    }
    var body: some View {
        Image(nsImage: base)
            .frame(width: TaskIndicatorLayout.canvasSize, height: TaskIndicatorLayout.canvasSize)
            .frame(width: layout.width, height: TaskIndicatorLayout.canvasSize, alignment: .leading)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(0..<layout.markerCount, id: \.self) { index in
                        if layout.isRunningMarker(index) {
                            Circle().strokeBorder(Color.primary, lineWidth: 1)
                                .frame(width: layout.markerSize(index), height: layout.markerSize(index))
                                .position(layout.position(index))
                        } else {
                            Circle().fill(VibeAppearance.accent)
                                .frame(width: layout.markerSize(index), height: layout.markerSize(index))
                                .position(layout.position(index))
                        }
                    }
                }
                .frame(width: layout.width, height: TaskIndicatorLayout.canvasSize)
                .allowsHitTesting(false)
            }
    }
}

struct TaskActivitySection: View {
    @ObservedObject var model: DeviceModel

    var body: some View {
        let sessions = model.taskActivity.orderedSessions
        GroupBox {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(L10n.text("mac.task_sessions")).font(.subheadline)
                    Spacer()
                    Text(
                        L10n.text(
                            "task.counts", max(0, model.taskActivity.runningCount),
                            max(0, model.taskActivity.unreadCount))
                    )
                    .font(.caption).foregroundStyle(VibeAppearance.secondary)
                    if model.taskActivity.unreadCount > 0 {
                        Button {
                            Task { await model.clearUnreadTasks() }
                        } label: {
                            if model.clearingUnread {
                                ProgressView().controlSize(.mini)
                            } else {
                                Label(L10n.text("mac.mark_all_viewed"), systemImage: "checkmark.circle").font(.caption)
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(!model.daemonRunning || model.openingTask != nil || model.clearingUnread)
                        .help(L10n.text("mac.clear_all_unviewed_indicators_in_this_menu_without_changing_the_prov"))
                        .accessibilityLabel(
                            L10n.text("mac.mark_all_0_unviewed_tasks_as_viewed", model.taskActivity.unreadCount))
                    }
                }
                if sessions.isEmpty {
                    Text(
                        model.daemonRunning
                            ? L10n.text("mac.no_running_tasks_or_unviewed_completions")
                            : L10n.text("mac.task_sessions_appear_after_the_service_starts")
                    )
                    .font(.caption).foregroundStyle(VibeAppearance.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(sessions, id: \.key) { session in
                                Button {
                                    Task { await model.openTaskSession(session) }
                                } label: {
                                    HStack(spacing: 7) {
                                        if session.isRunning {
                                            Circle().stroke(Color.primary, lineWidth: 1).frame(width: 7, height: 7)
                                        } else {
                                            Circle().fill(session.isUnread ? VibeAppearance.accent : Color.clear).frame(
                                                width: 7, height: 7)
                                        }
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(session.displayTitle).font(.subheadline).lineLimit(1)
                                            Text("\(session.providerLabel) · \(session.statusLabel)")
                                                .font(.caption).foregroundStyle(VibeAppearance.secondary)
                                        }
                                        Spacer(minLength: 4)
                                        if session.isRunning && session.isUnread {
                                            Circle().fill(VibeAppearance.accent).frame(width: 5, height: 5)
                                        }
                                        if model.openingTask == session.key {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(
                                                VibeAppearance.secondary)
                                        }
                                    }
                                    .padding(.vertical, 4).padding(.horizontal, 2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!model.daemonRunning || model.openingTask != nil || model.clearingUnread)
                                .help(L10n.text("mac.open_0_1", session.providerLabel, session.displayTitle))
                                .accessibilityLabel(
                                    L10n.text(
                                        "mac.0_1_2_open_session", session.providerLabel, session.displayTitle,
                                        session.statusLabel))
                            }
                        }
                    }
                    .frame(height: min(160, CGFloat(sessions.count) * 40))
                }
                if !model.taskActivityError.isEmpty {
                    Text(model.taskActivityError).font(.caption).foregroundStyle(VibeAppearance.danger).textSelection(
                        .enabled)
                }
            }
        }
    }
}
