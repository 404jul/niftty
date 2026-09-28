import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the prediction cascade's pure decision rules.
struct PredictionCascadeTests {
    // MARK: suffix(of:afterTyped:)

    @Test func suffixCompletesPartiallyTypedLastToken() {
        // Typed spacing is irrelevant: tokens align positionally.
        #expect(HistoryRecorder.suffix(of: "git status", afterTyped: "git    sta") == "tus")
    }

    @Test func suffixPrependsSpaceWhenLastTypedTokenIsComplete() {
        // Case-insensitive first-token match, whole token typed: the
        // suffix starts with the token separator.
        #expect(HistoryRecorder.suffix(of: "git status", afterTyped: "GIT") == " status")
    }

    @Test func suffixIsNilForExactMatch() {
        #expect(HistoryRecorder.suffix(of: "git status", afterTyped: "git status") == nil)
        // Case-insensitive exact match: still nothing to add.
        #expect(HistoryRecorder.suffix(of: "git status", afterTyped: "GIT STATUS") == nil)
    }

    @Test func suffixIsNilWhenTrailingSeparatorTerminatesNonMatchingToken() {
        // Regression: a trailing separator terminates the final typed
        // token, so "ss " is the complete token "ss", not a prefix of
        // "ssh" — suggesting would push the ghost text past the space.
        #expect(HistoryRecorder.suffix(of: "ssh julian@gx10", afterTyped: "ss ") == nil)
    }

    @Test func suffixContinuesWithWholeTokensAfterTrailingSeparator() {
        // After a trailing separator the suggestion starts at the next
        // whole command token; the separator is already on screen.
        #expect(HistoryRecorder.suffix(of: "git status", afterTyped: "git ") == "status")
        #expect(HistoryRecorder.suffix(of: "git status", afterTyped: "GIT ") == "status")
        // Fully typed plus separator: nothing left to suggest.
        #expect(HistoryRecorder.suffix(of: "git status", afterTyped: "git status ") == nil)
    }

    @Test func suffixIsNilOnTokenMismatch() {
        // "gt" is not a prefix of "git".
        #expect(HistoryRecorder.suffix(of: "git status", afterTyped: "gt") == nil)
        // More typed tokens than the command has.
        #expect(HistoryRecorder.suffix(of: "git status", afterTyped: "git status extra") == nil)
    }

    @Test func suffixMatchesQuotedStoredForm() {
        // Stored raw text is quoted, the typed prefix is not: tokens
        // flatten quoting so the match survives and the inserted
        // suffix is normalized.
        #expect(
            HistoryRecorder.suffix(of: "echo \"hello world\"", afterTyped: "echo hello")
                == " world")
    }

    @Test func suffixPreservesQuotingAfterTokenBoundary() {
        // After a trailing separator the suggestion is the raw stored
        // text: inserting it must reproduce the recorded command, not
        // its flattened form (which would run something else).
        #expect(
            HistoryRecorder.suffix(of: "grep \"foo bar\" file.txt", afterTyped: "grep ")
                == "\"foo bar\" file.txt")
        #expect(
            HistoryRecorder.suffix(of: "echo 'single quoted' arg", afterTyped: "echo ")
                == "'single quoted' arg")
    }

    @Test func suffixPreservesSubstitutionAfterTokenBoundary() {
        // Flattened tokens would turn `$(date)` into the literal word
        // `date`; the raw remainder keeps the substitution.
        #expect(
            HistoryRecorder.suffix(of: "tar czf backup-$(date +%F).tgz ~/docs", afterTyped: "tar czf ")
                == "backup-$(date +%F).tgz ~/docs")
        #expect(HistoryRecorder.suffix(of: "echo $(date)", afterTyped: "echo ") == "$(date)")
    }

    @Test func suffixFallsBackToFlattenedInsideSubstitution() {
        // Tokens matched from inside a substitution have no top-level
        // raw boundary to slice at: fall back to the flattened join.
        #expect(
            HistoryRecorder.suffix(of: "echo nested $(x y) done", afterTyped: "echo nested x ")
                == "y done")
    }

    // MARK: meetsGate(count:total:)

    @Test func meetsGateRequiresTwoRunsAndQuarterShare() {
        #expect(!HistoryRecorder.meetsGate(count: 1, total: 1))
        #expect(HistoryRecorder.meetsGate(count: 2, total: 8))
        #expect(!HistoryRecorder.meetsGate(count: 2, total: 10))
    }

    // MARK: validates(_:directory:isLocalContext:recordedDirectories:)

    /// Run `body` with `count` fresh, empty temporary directories
    /// (paths), removing them afterwards.
    private func withTemporaryDirectories(
        _ count: Int, _ body: ([String]) throws -> Void
    ) throws {
        let urls = (0..<count).map { _ in
            FileManager.default.temporaryDirectory
                .appendingPathComponent("niftty-validation-tests-\(UUID().uuidString)", isDirectory: true)
        }
        defer { for url in urls { try? FileManager.default.removeItem(at: url) } }
        for url in urls {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try body(urls.map(\.path))
    }

    @Test func cdTargetMustExistInTheCurrentDirectory() throws {
        try withTemporaryDirectories(1) { dirs in
            let here = dirs[0]
            // Regression: `cd folder/` from another directory's history
            // was suggested where `folder` does not exist.
            #expect(!HistoryRecorder.validates(
                "cd folder/", directory: here, isLocalContext: true, recordedDirectories: []))

            try FileManager.default.createDirectory(
                atPath: here + "/folder", withIntermediateDirectories: false)
            #expect(HistoryRecorder.validates(
                "cd folder/", directory: here, isLocalContext: true, recordedDirectories: []))
        }
    }

    @Test func bareFileArgumentResolvesAgainstCurrentNotRecordedDirectory() throws {
        try withTemporaryDirectories(2) { dirs in
            let (recordedIn, elsewhere) = (dirs[0], dirs[1])
            FileManager.default.createFile(atPath: recordedIn + "/notes.txt", contents: nil)

            // `notes.txt` is a file where the command was recorded, so
            // it is a path and must exist where the prompt is now.
            #expect(!HistoryRecorder.validates(
                "vim notes.txt", directory: elsewhere, isLocalContext: true,
                recordedDirectories: [recordedIn]))
            #expect(HistoryRecorder.validates(
                "vim notes.txt", directory: recordedIn, isLocalContext: true,
                recordedDirectories: [recordedIn]))
        }
    }

    @Test func slashedNonPathArgumentsPassLocally() throws {
        try withTemporaryDirectories(2) { dirs in
            let (recordedIn, here) = (dirs[0], dirs[1])
            // Neither word is a path in any recorded directory, so a
            // `/` alone must not reject them.
            #expect(HistoryRecorder.validates(
                "git checkout origin/main", directory: here, isLocalContext: true,
                recordedDirectories: [recordedIn]))
            #expect(HistoryRecorder.validates(
                "git clone https://github.com/a/b", directory: here, isLocalContext: true,
                recordedDirectories: [recordedIn]))
        }
    }

    @Test func remoteRelativePathNeedsSameDirectoryHistory() {
        // No disk to check remotely: history from this very directory
        // is the only evidence `src/` exists there.
        #expect(HistoryRecorder.validates(
            "cd src/", directory: "/home/u/proj", isLocalContext: false,
            recordedDirectories: ["/home/u/proj"]))
        #expect(!HistoryRecorder.validates(
            "cd src/", directory: "/home/u/proj", isLocalContext: false,
            recordedDirectories: ["/home/u/other"]))
        #expect(!HistoryRecorder.validates(
            "cd src/", directory: nil, isLocalContext: false,
            recordedDirectories: ["/home/u/proj"]))
        // Absolute paths cannot be checked remotely and pass.
        #expect(HistoryRecorder.validates(
            "cat /definitely/not/a/real/path/xyz", directory: "/home/u/proj",
            isLocalContext: false, recordedDirectories: []))
    }

    @Test func localAbsolutePathMustExist() {
        #expect(!HistoryRecorder.validates(
            "cat /definitely/not/a/real/path/xyz", directory: "/tmp", isLocalContext: true,
            recordedDirectories: []))
        #expect(HistoryRecorder.validates(
            "cat /tmp", directory: "/tmp", isLocalContext: true, recordedDirectories: []))
        // No PATH/executable check: shell functions and aliases must
        // not be false rejections.
        #expect(HistoryRecorder.validates(
            "zig build test", directory: "/tmp", isLocalContext: true, recordedDirectories: []))
    }
}
