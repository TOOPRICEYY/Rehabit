import XCTest
@testable import RehabitCore

final class InboxFilesTests: XCTestCase {
    func testNewestFirstPlaceholdersCountAndThePlainNameIsOldest() {
        let listing = ["rehabit-export.json", "rehabit-inbox.json", ".rehabit-inbox-20261117-183000.json.icloud",
                       "rehabit-inbox-20261117-120000.json", "rehabit-inbox-20261116-090000.json",
                       "rehabit-inboxes.json", "notes.txt", ".DS_Store", "rehabit-inbox-20261117-120000.json"]
        XCTAssertEqual(InboxFiles.names(in: listing), ["rehabit-inbox-20261117-183000.json",
                                                       "rehabit-inbox-20261117-120000.json",
                                                       "rehabit-inbox-20261116-090000.json",
                                                       "rehabit-inbox.json"])
        XCTAssertEqual(InboxFiles.names(in: [".rehabit-inbox.json.icloud"]), ["rehabit-inbox.json"])
        XCTAssertEqual(InboxFiles.names(in: ["rehabit-export.json", ".rehabit-export.json.icloud"]), [])
    }

    func testNames() {
        let date = Date(timeIntervalSince1970: 1_763_404_200)     // 2025-11-17 18:30:00 UTC
        XCTAssertEqual(InboxFiles.name(at: date), "rehabit-inbox-20251117-183000.json")
        XCTAssertEqual(InboxFiles.names(in: [InboxFiles.name(at: date)]), [InboxFiles.name(at: date)])
    }
}
