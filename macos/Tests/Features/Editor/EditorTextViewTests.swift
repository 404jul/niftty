import AppKit
import XCTest
@testable import Ghostty

final class EditorTextViewTests: XCTestCase {
    func testUndoRedoAndSelectAllShortcuts() throws {
        let textView = EditorTextView(frame: .zero)
        textView.allowsUndo = true
        textView.string = "alpha"
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertText(" beta", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "alpha beta")

        XCTAssertTrue(textView.performKeyEquivalent(with: try keyEvent("z", modifiers: .command)))
        XCTAssertEqual(textView.string, "alpha")

        XCTAssertTrue(textView.performKeyEquivalent(with: try keyEvent("z", modifiers: [.command, .shift])))
        XCTAssertEqual(textView.string, "alpha beta")

        XCTAssertTrue(textView.performKeyEquivalent(with: try keyEvent("a", modifiers: .command)))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 10))
    }

    private func keyEvent(
        _ key: String,
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: 0
        ))
    }
}
