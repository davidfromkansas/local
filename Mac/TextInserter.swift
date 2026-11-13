import AppKit

/// Types text into whatever app has focus: puts it on the clipboard, sends ⌘V, then puts the
/// previous clipboard back. Needs Accessibility permission.
enum TextInserter {
    static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }

        let changeCount = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Someone copied something new in the meantime: leave it.
            guard pasteboard.changeCount == changeCount, !saved.isEmpty else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            })
        }
    }
}
