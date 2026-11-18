import AppKit
import Testing
@testable import TouchGlassPanel

/// Records the edit actions that reach it, so no test touches the real pasteboard.
private final class RecordingView: NSView {
    var actions: [String] = []
    override var acceptsFirstResponder: Bool { true }
    @objc func paste(_ sender: Any?) { actions.append("paste") }
    @objc func cut(_ sender: Any?) { actions.append("cut") }
    @objc func undo(_ sender: Any?) { actions.append("undo") }
}

@MainActor
@Suite struct EditShortcutTests {
    init() {
        _ = NSApplication.shared
    }

    func key(_ character: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0
        )!
    }

    @Test func mapsStandardShortcuts() {
        #expect(PanelWindow.editAction(for: key("a", .command)) == #selector(NSText.selectAll(_:)))
        #expect(PanelWindow.editAction(for: key("v", .command)) == #selector(NSText.paste(_:)))
        #expect(PanelWindow.editAction(for: key("c", .command)) == #selector(NSText.copy(_:)))
        #expect(PanelWindow.editAction(for: key("x", .command)) == #selector(NSText.cut(_:)))
        #expect(PanelWindow.editAction(for: key("z", .command)) == Selector(("undo:")))
        #expect(PanelWindow.editAction(for: key("z", [.command, .shift])) == Selector(("redo:")))
        #expect(PanelWindow.editAction(for: key("a", [])) == nil)
        #expect(PanelWindow.editAction(for: key("a", [.command, .option])) == nil)
    }

    @Test func selectAllSelectsTheSecureFieldsText() throws {
        let window = PanelWindow()
        window.allowsKey = true
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.stringValue = "fake-pin-1"
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.fieldEditor(false, for: field) as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        #expect(window.performKeyEquivalent(with: key("a", .command)))
        #expect(editor.selectedRange() == NSRange(location: 0, length: 10))
    }

    @Test func pasteCutAndUndoReachTheFirstResponder() {
        let window = PanelWindow()
        window.allowsKey = true
        let view = RecordingView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView?.addSubview(view)
        #expect(window.makeFirstResponder(view))

        #expect(window.performKeyEquivalent(with: key("v", .command)))
        #expect(window.performKeyEquivalent(with: key("x", .command)))
        #expect(window.performKeyEquivalent(with: key("z", .command)))
        #expect(view.actions == ["paste", "cut", "undo"])
    }
}
