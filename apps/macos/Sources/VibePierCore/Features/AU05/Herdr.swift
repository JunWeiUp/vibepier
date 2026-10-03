// SPDX-License-Identifier: MIT
//
// Herdr integration (https://herdr.dev). Herdr runs coding agents in terminal
// panes and exposes them through `herdr agent list` and `herdr agent focus`.
// The daemon uses it for the hold-knob-and-turn gesture.

import AppKit
import Foundation

enum Herdr {
    struct Agent {
        var id: String
        var status: String
        var focused: Bool
        var name: String
    }

    enum HerdrError: Error, CustomStringConvertible {
        case notInstalled
        case failed(String)

        var description: String {
            switch self {
            case .notInstalled:
                return L10n.text("cli.herdr_missing")
            case .failed(let s): return "herdr: \(s)"
            }
        }
    }

    /// launchd starts the daemon with a minimal PATH, so check the usual places too.
    static func binary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin", "\(home)/.local/bin"]
        for d in dirs {
            let p = (d as NSString).appendingPathComponent("herdr")
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func run(_ args: [String]) throws -> Data {
        guard let bin = binary() else { throw HerdrError.notInstalled }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    /// Lists agents. The CLI prints one JSON object. Its error object is reported as
    /// is, and its agent records are found wherever they sit in the result.
    static func agents() throws -> [Agent] {
        let data = try run(["agent", "list"])
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw HerdrError.failed(String(decoding: data.prefix(300), as: UTF8.self))
        }
        if let dict = json as? [String: Any], let err = dict["error"] as? [String: Any] {
            throw HerdrError.failed((err["message"] as? String) ?? "\(err)")
        }
        var found: [Agent] = []
        collect(json, into: &found)
        return found
    }

    static func collect(_ value: Any, into out: inout [Agent]) {
        if let dict = value as? [String: Any] {
            // Herdr 0.9 identifies agents by pane_id. Older docs call it agent_id.
            if let id = (dict["agent_id"] as? String) ?? (dict["pane_id"] as? String), dict["agent_status"] != nil {
                out.append(
                    Agent(
                        id: id, status: (dict["agent_status"] as? String) ?? "unknown",
                        focused: (dict["focused"] as? Bool) ?? false,
                        name: (dict["terminal_title_stripped"] as? String) ?? (dict["agent"] as? String)
                            ?? (dict["name"] as? String) ?? id))
                return
            }
            for key in dict.keys.sorted() { collect(dict[key]!, into: &out) }
        } else if let array = value as? [Any] {
            for v in array { collect(v, into: &out) }
        }
    }

    static func focus(_ id: String) throws {
        let data = try run(["agent", "focus", id])
        if let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let err = dict["error"] as? [String: Any]
        {
            throw HerdrError.failed((err["message"] as? String) ?? "\(err)")
        }
    }

    /// Focuses the next (`step` = 1) or previous (`step` = -1) agent, starting from
    /// the focused one, or from the last agent that vibepier focused.
    @discardableResult
    static func cycle(step: Int, after lastID: String?) throws -> Agent? {
        let list = try agents()
        guard !list.isEmpty else { return nil }
        let current = list.firstIndex(where: \.focused) ?? lastID.flatMap { id in list.firstIndex { $0.id == id } }
        let next: Int
        if let current {
            next = ((current + step) % list.count + list.count) % list.count
        } else {
            next = step > 0 ? 0 : list.count - 1
        }
        try focus(list[next].id)
        return list[next]
    }

    /// Finds the app that hosts a Herdr client. It walks from each `herdr` process
    /// up the parent chain to the first regular app, for example iTerm2 or Ghostty.
    static func terminalApp() -> NSRunningApplication? {
        let data = (try? runTool("/usr/bin/pgrep", ["-x", "herdr"])) ?? Data()
        let pids = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
        for start in pids {
            var pid = start
            for _ in 0..<16 {
                if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                    return app
                }
                guard let parent = parentPID(pid), parent > 1 else { break }
                pid = parent
            }
        }
        return nil
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    static func runTool(_ path: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    /// Brings the terminal to the front. `appName` overrides the detection. A
    /// background process cannot activate another app directly on macOS 14 and
    /// later, so this asks LaunchServices through `open -b`.
    /// The bounds of the frontmost normal window of a process, in global display
    /// points with the origin at the top left. Window bounds need no Screen
    /// Recording permission.
    static func frontWindowBounds(pid: pid_t) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                (w[kCGWindowLayer as String] as? Int) == 0,
                let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
                rect.width > 100, rect.height > 100
            else { continue }
            return rect
        }
        return nil
    }

    /// Moves the pointer to a corner of the front window of `pid`, unless the
    /// pointer is already inside that window. Scroll events go to the window
    /// under the pointer, so this makes the knob scroll the terminal.
    static func movePointer(toCorner corner: String, ofPID pid: pid_t) -> Bool {
        guard let rect = frontWindowBounds(pid: pid) else { return false }
        let current = CGEvent(source: nil)?.location ?? .zero
        if rect.contains(current) { return true }
        let inset: CGFloat = 40
        let x = corner == "bottom-left" ? rect.minX + inset : rect.maxX - inset
        let point = CGPoint(x: x, y: rect.maxY - inset)
        CGWarpMouseCursorPosition(point)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    static func bringTerminalToFront(appName: String?, pointerCorner: String = "off") -> String? {
        var target: NSRunningApplication?
        if let appName {
            target = NSWorkspace.shared.runningApplications.first {
                $0.localizedName?.lowercased() == appName.lowercased()
                    || $0.bundleIdentifier?.lowercased() == appName.lowercased()
            }
        } else {
            target = terminalApp()
        }
        guard let app = target, let bundle = app.bundleIdentifier else { return nil }
        _ = try? runTool("/usr/bin/open", ["-b", bundle])
        if pointerCorner != "off" {
            // Give the window server a moment to reorder the windows.
            usleep(150_000)
            _ = movePointer(toCorner: pointerCorner, ofPID: app.processIdentifier)
        }
        return app.localizedName ?? bundle
    }
}
