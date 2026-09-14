import XCTest
@testable import Ghostty

final class EditorDocumentTests: XCTestCase {
    func testSavePersistsTextAndClearsDirtyState() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }

        try "alpha\n".write(to: url, atomically: true, encoding: .utf8)
        let document = try EditorDocument(url: url)

        XCTAssertEqual(document.text, "alpha\n")
        XCTAssertFalse(document.isDirty)

        document.text = "beta\n"
        XCTAssertTrue(document.isDirty)

        document.save()

        XCTAssertNil(document.saveError)
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "beta\n")
    }
}
