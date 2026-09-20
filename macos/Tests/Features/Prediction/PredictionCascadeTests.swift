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
