import AppKit
import Foundation

struct FrontmostApplication: Codable, Equatable, Sendable {
    let bundleID: String
    let name: String

    static func current() -> Self {
        let app = NSWorkspace.shared.frontmostApplication
        return Self(
            bundleID: app?.bundleIdentifier ?? "", name: app?.localizedName ?? L10n.text("control.unknown_application"))
    }
}
