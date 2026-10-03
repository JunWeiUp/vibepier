import AppKit

/// Saves a bounded clipboard snapshot, then restores it only while the operation still owns its contents.
/// Callers pass the board explicitly so tests never touch the user's general clipboard.
final class DesktopClipboard {
    private let board: NSPasteboard
    private let saved: [[(NSPasteboard.PasteboardType, Data)]]
    private let baseline: Int
    private var owned: Int?
    private var expectedText: String?
    private let token = UUID().uuidString
    private static let marker = NSPasteboard.PasteboardType("io.github.junweiup.vibepier.transient-owner")

    init(_ board: NSPasteboard, byteLimit: Int = 16 * 1024 * 1024) throws {
        self.board = board
        baseline = board.changeCount
        let items = board.pasteboardItems ?? []
        guard byteLimit >= 0, items.count <= 32 else { throw Self.unavailable() }
        var saved: [[(NSPasteboard.PasteboardType, Data)]] = []
        var bytes = 0
        var types = 0
        for item in items {
            types += item.types.count
            guard types <= 128 else { throw Self.unavailable() }
            var values: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type), data.count <= byteLimit - bytes else {
                    throw Self.unavailable()
                }
                bytes += data.count
                values.append((type, data))
            }
            saved.append(values)
        }
        guard board.changeCount == baseline else { throw Self.unavailable() }
        self.saved = saved
    }

    func write(_ text: String) throws {
        guard owned == nil, board.changeCount == baseline else { throw Self.unavailable() }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(token, forType: Self.marker)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        owned = board.clearContents()
        guard board.writeObjects([item]) else {
            // A failed write may leave just the empty board from clearContents().
            if board.changeCount == owned, (board.types ?? []).isEmpty { restoreSaved() }
            throw Self.unavailable()
        }
        owned = board.changeCount
        expectedText = nil
        guard isCurrent else { throw Self.unavailable() }
    }

    var isCurrent: Bool {
        guard let owned, board.changeCount == owned else { return false }
        if let expectedText { return board.string(forType: .string) == expectedText && board.changeCount == owned }
        return board.string(forType: Self.marker) == token && board.changeCount == owned
    }

    /// The native Copy Session ID action replaces our marker. Keep the exact observed version
    /// for cleanup; a subsequent user copy must survive. This does not authenticate the clipboard writer.
    func adoptNativeCopy(_ text: String, version: Int) -> Bool {
        guard let owned, version != owned, board.changeCount == version,
            board.string(forType: .string) == text, board.changeCount == version
        else { return false }
        self.owned = version
        expectedText = text
        return true
    }

    func restore() {
        guard isCurrent else { return }
        restoreSaved()
    }

    private func restoreSaved() {
        owned = nil
        let items = saved.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        board.clearContents()
        if !items.isEmpty { board.writeObjects(items) }
    }

    private static func unavailable() -> CLIError { CLIError(L10n.text("provider.desktop_clipboard_unavailable")) }
}
