import Foundation
import SQLite3
import Testing
@testable import Ghostty

struct HistoryStoreTests {
    // MARK: Helpers

    private func makeStore() -> (store: HistoryStore, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("niftty-history-tests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("history.db")
        return (HistoryStore(url: url), url)
    }

    /// Run a test body with a fresh store, closing the database and
    /// removing its files on every exit path. The store must be closed
    /// before the files are deleted: unlinking files under an open WAL
    /// connection is an sqlite API violation.
    private func withStore(
        _ body: (HistoryStore, URL) async throws -> Void
    ) async throws {
        let (store, url) = makeStore()
        do {
            try await body(store, url)
            await store.close()
        } catch {
            await store.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            throw error
        }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Open the database file read-only and return the first column of
    /// the first row, validating the on-disk artifact directly.
    private func scalar(_ url: URL, _ sql: String) -> Int64? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db
        else {
            sqlite3_close_v2(db)
            return nil
        }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func record(
        _ store: HistoryStore,
        _ command: String,
        exitCode: Int32? = 0,
        directory: String? = nil,
        previous: String? = nil
    ) async {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        await store.record(
            command: command,
            exitCode: exitCode,
            startedAt: date,
            finishedAt: date,
            host: nil,
            directory: directory,
            previousCommand: previous
        )
    }

    // MARK: Recording

    @Test func recordTwiceBumpsUseCount() async throws {
        try await withStore { store, url in
            await record(store, "git st", exitCode: 0)
            await record(store, "  git   st ", exitCode: 1)

            let useCount = try #require(scalar(url, "SELECT use_count FROM command WHERE normalized = 'git st'"))
            #expect(useCount == 2)
            let successCount = try #require(scalar(url, "SELECT success_count FROM command WHERE normalized = 'git st'"))
            #expect(successCount == 1)
            let commandCount = try #require(scalar(url, "SELECT COUNT(*) FROM command"))
            #expect(commandCount == 1)
        }
    }

    @Test func recordPersistsFeatureRows() async throws {
        try await withStore { store, url in
            await record(store, "zig build")
            // One row per distinct feature hash: 2 unigrams, 1 bigram,
            // plus char n-grams (zig: 5, build: 9).
            let featureCount = try #require(scalar(url, "SELECT COUNT(*) FROM feature WHERE extractor = \(CommandFeatureExtractor.version)"))
            #expect(featureCount == 17)
        }
    }

    @Test func whitespaceOnlyCommandIsSkipped() async throws {
        try await withStore { store, url in
            await record(store, "   \t ")
            let commandCount = try #require(scalar(url, "SELECT COUNT(*) FROM command"))
            #expect(commandCount == 0)
        }
    }

    @Test func acceptanceBumpsAcceptedCount() async throws {
        try await withStore { store, url in
            await record(store, "zig build")
            let id = try #require(scalar(url, "SELECT id FROM command WHERE normalized = 'zig build'"))
            await store.recordAcceptance(commandID: id)
            // Unknown ids are a no-op, not a failure.
            await store.recordAcceptance(commandID: 999_999)

            let accepted = try #require(scalar(url, "SELECT accepted_count FROM command WHERE id = \(id)"))
            #expect(accepted == 1)
        }
    }

    @Test func transitionStoredInDirectoryScope() async throws {
        try await withStore { store, url in
            await record(store, "make", directory: "/x")
            await record(store, "make test", directory: "/x", previous: "make")

            let count = try #require(scalar(url, """
                SELECT t.count FROM transition t
                JOIN command p ON p.id = t.prev_id
                JOIN command n ON n.id = t.next_id
                WHERE p.normalized = 'make' AND n.normalized = 'make test' AND t.directory = '/x'
                """))
            #expect(count == 1)
        }
    }

    // MARK: Retrieval

    @Test func emptyStoreReturnsNoCandidates() async throws {
        try await withStore { store, _ in
            let rows = await store.topCandidates(
                previous: "anything", directory: nil,
                extractor: CommandFeatureExtractor.version, limit: 20)
            #expect(rows.isEmpty)
        }
    }

    @Test func transitionRanksNextCommandFirst() async throws {
        try await withStore { store, _ in
            await record(store, "git st")
            await record(store, "git push", previous: "git st")
            await record(store, "cargo build")

            let rows = await store.topCandidates(
                previous: "git st", directory: nil,
                extractor: CommandFeatureExtractor.version, limit: 20)
            #expect(rows.first?.text == "git push")
            #expect(rows.first?.score ?? 0 >= 1.0)
            // The previous command itself is never a candidate.
            #expect(!rows.contains { $0.text == "git st" })
        }
    }

    @Test func directoryMatchTriplesTransitionWeight() async throws {
        try await withStore { store, _ in
            await record(store, "make", directory: "/x")
            // Same follow-up via a global transition row, then via a
            // directory-scoped row.
            await record(store, "make test", directory: nil, previous: "make")
            await record(store, "make test", directory: "/x", previous: "make")

            let global = await store.topCandidates(
                previous: "make", directory: nil,
                extractor: CommandFeatureExtractor.version, limit: 20)
            let scoped = await store.topCandidates(
                previous: "make", directory: "/x",
                extractor: CommandFeatureExtractor.version, limit: 20)

            #expect(global.first?.text == "make test")
            #expect(scoped.first?.text == "make test")
            // Identical candidate rows, so identical feature mass and
            // priors. The global query (directory nil) counts every
            // transition row ×1; the scoped query weights the /x row
            // ×3, so the delta is exactly (3.0 - 1.0) × count.
            let globalScore = try #require(global.first?.score)
            let scopedScore = try #require(scoped.first?.score)
            #expect(abs((scopedScore - globalScore) - 2.0) < 1e-9)
        }
    }

    // MARK: Degradation

    @Test func acceptanceTipsTieBetweenIdenticalPeers() async throws {
        try await withStore { store, url in
            await record(store, "git st")
            // Identical records: two uses, one success each, equal
            // transition mass, and the helper's frozen timestamps, so
            // without acceptance weighting the scores tie exactly and
            // the strict comparison below fails.
            await record(store, "git push", exitCode: 0, previous: "git st")
            await record(store, "git push", exitCode: 1, previous: "git st")
            await record(store, "git pull", exitCode: 0, previous: "git st")
            await record(store, "git pull", exitCode: 1, previous: "git st")

            // Accepting `git push` lifts its feedback rate from 0.5 to
            // the cap, strictly outranking `git pull`.
            let pushID = try #require(scalar(url, "SELECT id FROM command WHERE normalized = 'git push'"))
            await store.recordAcceptance(commandID: pushID)

            let rows = await store.topCandidates(
                previous: "git st", directory: nil,
                extractor: CommandFeatureExtractor.version, limit: 20)
            let push = try #require(rows.first { $0.text == "git push" })
            let pull = try #require(rows.first { $0.text == "git pull" })
            #expect(push.score > pull.score)
        }
    }

    @Test func corruptDatabaseDisablesStoreAndMethodsNoOp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("niftty-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.db")
        try Data("definitely not a sqlite database".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(url: url)
        let disabled = await store.disabled
        #expect(disabled)

        // Every method stays a silent no-op.
        await record(store, "ls")
        let rows = await store.topCandidates(
            previous: "ls", directory: nil,
            extractor: CommandFeatureExtractor.version, limit: 5)
        #expect(rows.isEmpty)
        await store.recordAcceptance(commandID: 1)
        await store.close()
    }
}
