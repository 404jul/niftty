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

    // MARK: validatesOnLocalDisk(_:isLocalContext:)

    @Test func validationRejectsMissingLocalPath() {
        #expect(!HistoryRecorder.validatesOnLocalDisk(
            "cat /definitely/not/a/real/path/xyz",
            isLocalContext: true))
    }

    @Test func validationSkipsRemoteContexts() {
        // Remote prompts have no local disk to check against.
        #expect(HistoryRecorder.validatesOnLocalDisk(
            "cat /definitely/not/a/real/path/xyz",
            isLocalContext: false))
    }

    @Test func validationPassesNonPathTokensAndExistingPaths() {
        // No PATH/executable check: shell functions and aliases must
        // not be false rejections.
        #expect(HistoryRecorder.validatesOnLocalDisk(
            "zig build test", isLocalContext: true))
        #expect(HistoryRecorder.validatesOnLocalDisk(
            "cat /tmp", isLocalContext: true))
    }
}
