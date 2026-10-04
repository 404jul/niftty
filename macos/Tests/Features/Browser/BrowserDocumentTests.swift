import XCTest
@testable import Ghostty

final class BrowserDocumentTests: XCTestCase {
    func testDestinationPrefixesHTTPSForBareHosts() {
        XCTAssertEqual(
            BrowserDestination.destination(for: "example.com")?.absoluteString,
            "https://example.com"
        )
        XCTAssertEqual(
            BrowserDestination.destination(for: "localhost:3000")?.absoluteString,
            "https://localhost:3000"
        )
        XCTAssertEqual(
            BrowserDestination.destination(for: "192.168.1.10:8080")?.absoluteString,
            "https://192.168.1.10:8080"
        )
    }

    func testDestinationKeepsExplicitScheme() {
        XCTAssertEqual(
            BrowserDestination.destination(for: "http://example.com/x")?.absoluteString,
            "http://example.com/x"
        )
        XCTAssertEqual(
            BrowserDestination.destination(for: "https://example.com")?.absoluteString,
            "https://example.com"
        )
        XCTAssertEqual(
            BrowserDestination.destination(for: "file:///tmp/a.html")?.absoluteString,
            "file:///tmp/a.html"
        )
    }

    func testDestinationFallsBackToSearch() {
        let url = BrowserDestination.destination(for: "how do i exit vim")
        XCTAssertEqual(url?.host, "duckduckgo.com")
        // Encoding of spaces (+ vs %20) varies across Foundation versions;
        // assert the query param robustly.
        let query = url?.query ?? ""
        XCTAssertTrue(query.contains("q=how"), "query was: \(query)")
        XCTAssertTrue(query.contains("vim"), "query was: \(query)")
    }

    func testDestinationRejectsUnknownSchemesAndEmptyInput() {
        XCTAssertNil(BrowserDestination.destination(for: "slack://channel"))
        XCTAssertNil(BrowserDestination.destination(for: "   "))
        XCTAssertNil(BrowserDestination.destination(for: ""))
    }

    func testDocumentInitialState() {
        let blank = BrowserDocument()
        XCTAssertNil(blank.url)
        XCTAssertEqual(blank.addressText, "")

        let seeded = BrowserDocument(url: URL(string: "https://example.com")!)
        XCTAssertEqual(seeded.addressText, "https://example.com")
    }
}
