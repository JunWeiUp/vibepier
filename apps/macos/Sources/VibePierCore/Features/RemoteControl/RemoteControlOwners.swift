// SPDX-License-Identifier: MIT

import VibeKit

/// Each held remote control belongs to the phone that pressed it. Relay and UDP
/// use the same phone ID, so a path change can still release the original press.
struct RemoteControlOwners {
    private var holders: [Control: String] = [:]

    static func identity(_ sender: String) -> String {
        sender.hasPrefix("relay:") ? String(sender.dropFirst(6)) : sender
    }

    func owner(_ control: Control) -> String? { holders[control] }
    func owns(_ control: Control, sender: String) -> Bool { holders[control] == Self.identity(sender) }

    mutating func accept(_ event: RemoteEvent) -> Bool {
        guard let control = event.control else { return false }
        let sender = Self.identity(event.sender)
        if let owner = holders[control], owner != sender { return false }
        if event.isMomentary { return control != .talk }
        if event.event == "down" {
            if holders[control] != nil { return control == .talk }
            holders[control] = sender
            return true
        }
        guard event.event == "up", holders[control] == sender else { return false }
        holders.removeValue(forKey: control)
        return true
    }

    mutating func removeAll() { holders.removeAll() }
}
