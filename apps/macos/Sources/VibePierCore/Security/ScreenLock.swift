import AppKit
import Foundation
import IOKit.pwr_mgt
import OpenDirectory
import Security

/// Phone actions that drive a desktop app (pasting into Claude, pressing Return in Codex) would type into the
/// loginwindow while the screen is locked. With a password the phone configured, the Mac unlocks itself first —
/// the password is checked against this account before it is saved, so a wrong one is never typed — and locks
/// again once the last such action is done. Without one, those actions fail with a clear error instead.
public enum ScreenLock {
    private static let service = "io.github.junweiup.vibepier.unlock.v1"
    private static let controller = ScreenLockController(
        isLocked: { locked() }, unlock: { try unlockScreen() },
        lock: {
            lock()
            guard wait(3, { locked() }) else {
                throw CLIError(L10n.text("core.could_not_confirm_that_the_mac_locked_check_on_the_mac"))
            }
        })

    public static func locked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
    public static func configured() -> Bool { password() != nil }
    static var lockedError: CLIError {
        CLIError(L10n.text("core.the_mac_is_locked_configure_its_password_in_the_phone_s_session_menu"))
    }

    static func status() -> [String: Any] {
        return ["ok": true, "configured": password() != nil, "locked": locked(), "failed": controller.failed]
    }

    /// Saves the login password after verifying it; an empty one removes it.
    static func save(_ value: String) throws {
        if value.isEmpty {
            let status = SecItemDelete(query() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CLIError(L10n.text("core.could_not_remove_the_unlock_password_0", status))
            }
            controller.resetFailure()
            return
        }
        guard value.utf8.count <= 256 else { throw CLIError(L10n.text("core.the_password_is_too_long")) }
        guard verify(value) else {
            throw CLIError(
                L10n.text("core.the_password_does_not_match_the_current_mac_user_0_it_was_not_saved", NSUserName()))
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query()
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw CLIError(L10n.text("core.could_not_save_the_unlock_password_0", status))
        }
        controller.resetFailure()
    }

    /// Runs a desktop action with the screen unlocked, unlocking first and locking again afterwards if needed.
    static func unlocked<T>(_ body: () throws -> T) throws -> T {
        try acquire()
        defer { release() }
        return try body()
    }

    /// Marks a desktop action as running. Every successful call must be balanced by `release()`.
    static func acquire() throws { try controller.acquire() }
    static func release() { controller.release() }
    static func lockNow() throws { try controller.lockNow() }
    static func unlockNow() throws { try controller.unlockNow() }

    private static func unlockScreen() throws {
        guard let password = password() else { throw lockedError }
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

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
        ]
    }
    private static func password() -> String? {
        var item: CFTypeRef?
        var search = query()
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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
