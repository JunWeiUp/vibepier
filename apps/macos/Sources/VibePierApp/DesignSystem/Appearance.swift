import AppKit
import SwiftUI

/// Shared graphite / mint palette matching the phone, with a native light appearance on macOS. Surfaces are
/// separated by lightness rather than outlines; mint marks only the primary action, live work and the selection.
enum VibeAppearance {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat((value >> 16) & 255) / 255,
                    green: CGFloat((value >> 8) & 255) / 255,
                    blue: CGFloat(value & 255) / 255, alpha: 1)
            })
    }
    static let background = adaptive(0xF3F5F6, 0x0F1416)
    static let sidebar = adaptive(0xE9EDEF, 0x13191B)
    static let surface = adaptive(0xFFFFFF, 0x161C1F)
    static let surface2 = adaptive(0xEEF1F3, 0x1C2427)
    static let surface3 = adaptive(0xE3E8EA, 0x242D31)
    static let text = adaptive(0x172126, 0xE9EEF0)
    static let secondary = adaptive(0x55636A, 0xA3AFB4)
    static let faint = adaptive(0x76848A, 0x7F8C92)
    static let outline = adaptive(0xD5DCDF, 0x232B2F)
    static let accent = adaptive(0x0B7A63, 0x72D4B9)
    static let accentContainer = adaptive(0xDDF2EC, 0x1B2E2B)
    static let blue = adaptive(0x2F6DB5, 0x86B4EE)
    static let blueContainer = adaptive(0xE3EEFB, 0x1E2832)
    static let danger = adaptive(0xB4232D, 0xE8837C)
    static let warning = adaptive(0x865300, 0xE8B86F)
    static let warningContainer = adaptive(0xFBF0DD, 0x2B2922)
}

private struct VibeGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(.caption.weight(.semibold)).foregroundStyle(VibeAppearance.secondary)
            configuration.content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VibeAppearance.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A line icon on a tinted rounded tile, naming a row's category at a glance.
struct IconBadge: View {
    let symbol: String
    var tint: Color = VibeAppearance.secondary
    var container: Color = VibeAppearance.surface3
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(container, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension View {
    func vibeAppearance() -> some View {
        self.foregroundStyle(VibeAppearance.text)
            .tint(VibeAppearance.accent)
            .groupBoxStyle(VibeGroupBoxStyle())
            .background(VibeAppearance.background)
    }
    func vibeCard(radius: CGFloat = 14, color: Color = VibeAppearance.surface) -> some View {
        self.background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
