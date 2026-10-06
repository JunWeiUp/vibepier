import AppKit
import Foundation
import IOKit.pwr_mgt
import OpenDirectory

/// Phone actions that drive a desktop app (pasting into Claude, pressing Return in Codex) would type into the
/// loginwindow while the screen is locked. With a password the phone configured, the Mac unlocks itself first —
/// the password is checked against this account before it is saved, so a wrong one is never typed — and locks
/// again once the last such action is done. Without one, those actions fail with a clear error instead.
public enum ScreenLock {
    private static let preferences = UnlockPreferences(
        file: Paths.supportDirectory.appendingPathComponent("preferences/unlock.json"), account: NSUserName())
    private static let controller = ScreenLockController(
        isLocked: { locked() }, unlock: { try unlockScreen() },
        lock: {
            lock()
            guard wait(3, { locked() }) else {
                throw CLIError(L10n.text("core.could_not_confirm_that_the_mac_locked_check_on_the_mac"))
            }
        },
        // Phone-driven unlocks stay open while the phone keeps working, then lock again after two idle minutes.
        relockGrace: 120,
        schedule: { delay, work in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
        },
        localIdleSeconds: {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        })

    public static func locked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
    public static func configured() -> Bool { (try? preferences.read()) != nil }
    static var lockedError: CLIError {
        CLIError(L10n.text("core.the_mac_is_locked_configure_its_password_in_the_phone_s_session_menu"))
    }

    static func status() -> [String: Any] {
        do {
            return [
                "ok": true, "configured": try preferences.read() != nil, "locked": locked(),
                "failed": controller.failed,
            ]
        } catch { return ["ok": false, "error": String(describing: error), "locked": locked()] }
    }

    /// Owner-only diagnosis. Never returns password text or editable field contents, and sends no input.
    static func diagnostics() -> [String: Any] {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        var saved: String?
        var preferencesError: String?
        do { saved = try preferences.read() } catch { preferencesError = String(describing: error) }
        var result: [String: Any] = [
            "ok": true, "locked": locked(), "configured": saved != nil, "passwordStorage": "mac-preferences",
            "previousAttemptFailed": controller.failed, "accessibilityTrusted": AXIsProcessTrusted(),
            "onConsole": session[kCGSessionOnConsoleKey as String] as? Bool ?? false,
            "frontmostIsLoginWindow": NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == "com.apple.loginwindow",
        ]
        if let preferencesError { result["preferencesError"] = preferencesError }
        if let saved { result["storedPasswordVerification"] = verify(saved) ? "verified" : "not_verified" }
        if locked(),
            let login = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow").first
        {
            let app = AXUIElementCreateApplication(login.processIdentifier)
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &raw)
            result["lockFieldReadStatus"] = status.rawValue
            if status == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() {
                let field = unsafeBitCast(raw, to: AXUIElement.self)
                for (name, key) in [("lockFieldRole", kAXRoleAttribute), ("lockFieldSubrole", kAXSubroleAttribute)] {
                    var attribute: CFTypeRef?
                    if AXUIElementCopyAttributeValue(field, key as CFString, &attribute) == .success,
                        let value = attribute as? String
                    {
                        result[name] = value
                    }
                }
            }
        }
        return result
    }

    /// Saves the login password after verifying it; an empty one removes it.
    static func save(_ value: String) throws {
        if value.isEmpty {
            try preferences.save(nil)
            controller.resetFailure()
            return
        }
        guard value.utf8.count <= 256 else { throw CLIError(L10n.text("core.the_password_is_too_long")) }
        guard verify(value) else {
            throw CLIError(
                L10n.text("core.the_password_does_not_match_the_current_mac_user_0_it_was_not_saved", NSUserName()))
        }
        try preferences.save(value)
        controller.resetFailure()
    }

    /// Runs a desktop action with the screen unlocked, unlocking first and locking again afterwards if needed.
    static func unlocked<T>(_ body: () throws -> T) throws -> T {
        try acquire()
        defer { release() }
        return try body()
    }

    /// Unlocks first when a password is configured; otherwise runs as-is (IPC-only actions may still succeed).
    static func preferUnlocked<T>(_ body: () throws -> T) throws -> T {
        guard locked(), configured() else { return try body() }
        return try unlocked(body)
    }

    /// Marks a desktop action as running. Every successful call must be balanced by `release()`.
    static func acquire() throws { try controller.acquire() }
    static func release() { controller.release() }
    static func lockNow() throws { try controller.lockNow() }
    static func unlockNow() throws { try controller.unlockNow() }

    private static func unlockScreen() throws {
        guard let password = try preferences.read() else { throw lockedError }
        guard Replay.checkAccessibility(prompt: false) else {
            throw CLIError(L10n.text("core.allow_accessibility_permission_for_vibepier_in_mac_system_settings_f"))
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard session?[kCGSessionOnConsoleKey as String] as? Bool ?? false else {
            throw CLIError(L10n.text("core.a_different_user_is_logged_in_on_the_mac_cannot_unlock_it"))
        }
        type(password)
        guard wait(8, { !locked() }) else { throw ScreenUnlockAttemptFailed() }
        Thread.sleep(forTimeInterval: 0.8)
    }

    private static func verify(_ value: String) -> Bool {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication)),
            let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        else { return false }
        return (try? record.verifyPassword(value)) != nil
    }
    private static func wait(_ seconds: Double, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return done()
    }
    private static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        KeySynth.post(code, down: true, flags: flags)
        KeySynth.post(code, down: false, flags: flags)
    }
    /// Wakes the display, then types into the lock screen's password field.
    private static func type(_ password: String) {
        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("vibepier unlock" as CFString, kIOPMUserActiveLocal, &assertion)
        Thread.sleep(forTimeInterval: 1.0)
        key(56)  // Shift: dismisses a screen saver without typing anything.
        Thread.sleep(forTimeInterval: 0.6)
        key(0, flags: .maskCommand)
        key(51)  // Clear anything already in the field.
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(password.utf16)
        // The window server takes at most 20 UTF-16 units per keyboard event.
        for start in stride(from: 0, to: units.count, by: 20) {
            var chunk = Array(units[start..<min(start + 20, units.count)])
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: down)
                if down { event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk) }
                event?.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.1)
        key(36)
    }
    private static func lock() {
        typealias Lock = @convention(c) () -> Void
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
            let symbol = dlsym(handle, "SACLockScreenImmediate")
        {
            unsafeBitCast(symbol, to: Lock.self)()
            return
        }
        key(12, flags: [.maskCommand, .maskControl])  // ⌃⌘Q
    }
}
