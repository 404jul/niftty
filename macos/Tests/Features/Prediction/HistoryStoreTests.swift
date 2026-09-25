import Foundation
import SQLite3
import Testing
@testable import Ghostty

struct HistoryStoreTests {
    /// Frozen timestamp so recency-derived priors are deterministic.
    private static let frozenDate = Date(timeIntervalSince1970: 1_700_000_000)

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
        host: String? = nil,
        previous: String? = nil,
        at date: Date = HistoryStoreTests.frozenDate
    ) async {
        await store.record(
            command: command,
            exitCode: exitCode,
            startedAt: date,
            finishedAt: date,
            host: host,
            directory: directory,
            previousCommand: previous
        )
    }

    /// Follow-up candidates for `previous` in a given context.
    private func followUps(
        _ store: HistoryStore,
        previous: String,
        directory: String? = nil,
        host: String? = nil,
        exitCode: Int32 = 0
    ) async -> [HistoryStore.CandidateRow] {
        await store.topCandidates(
            previous: previous,
            directory: directory,
            host: host,
            exitCode: exitCode,
            extractor: CommandFeatureExtractor.version,
            limit: 20)
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

    @Test func transitionRowsSplitByExitCode() async throws {
        try await withStore { store, url in
            await record(store, "git st", directory: "/x")
            await record(store, "git push", exitCode: 0, directory: "/x", previous: "git st")
            await record(store, "git push", exitCode: 1, directory: "/x", previous: "git st")

            // One upserted command identity...
            let useCount = try #require(scalar(url, "SELECT use_count FROM command WHERE normalized = 'git push'"))
            #expect(useCount == 2)
            // ...but its transition rows split per exit code, so the
            // exit-0 query only ever counts exit-0 evidence.
            let transitionRows = try #require(scalar(url, """
                SELECT COUNT(*) FROM transition t
                JOIN command n ON n.id = t.next_id
                WHERE n.normalized = 'git push'
                """))
            #expect(transitionRows == 2)
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

    @Test func occurrenceRecordsWhereTheCommandRan() async throws {
        try await withStore { store, url in
            await record(store, "git push", directory: "/x")
            await record(store, "git push", directory: "/x")

            // One row per (command, directory, host); re-runs bump
            // last_seen only.
            let occurrences = try #require(scalar(url, "SELECT COUNT(*) FROM occurrence"))
            #expect(occurrences == 1)
        }
    }

    // MARK: Retrieval

    @Test func emptyStoreReturnsNoCandidates() async throws {
        try await withStore { store, _ in
            let rows = await followUps(store, previous: "anything")
            #expect(rows.isEmpty)
            let prefixRows = await store.contextPrefixCandidates(
                previous: "anything", directory: nil, host: nil, exitCode: 0,
                prefix: "any", extractor: CommandFeatureExtractor.version, limit: 20)
            #expect(prefixRows.isEmpty)
            let recentRows = await store.recentPrefixCandidates(prefix: "any", directory: nil, limit: 20)
            #expect(recentRows.isEmpty)
        }
    }

    @Test func transitionRanksNextCommandFirst() async throws {
        try await withStore { store, _ in
            await record(store, "git st")
            await record(store, "git push", previous: "git st")
            await record(store, "cargo build")

            let rows = await followUps(store, previous: "git st")
            #expect(rows.first?.text == "git push")
            #expect(rows.first?.contextCount == 1)
            #expect(rows.first?.contextTotal == 1)
            // The previous command itself is never a candidate, and a
            // command with no transition from `git st` never pools in
            // (feature overlap alone no longer suggests anything).
            #expect(!rows.contains { $0.text == "git st" })
            #expect(!rows.contains { $0.text == "cargo build" })
        }
    }

    @Test func directoryMatchTriplesTransitionWeight() async throws {
        try await withStore { store, _ in
            await record(store, "make", directory: "/x")
            // Same follow-up via a host-less transition row, then via a
            // /x-scoped row.
            await record(store, "make test", previous: "make")
            await record(store, "make test", directory: "/x", previous: "make")

            let global = await followUps(store, previous: "make")
            let scoped = await followUps(store, previous: "make", directory: "/x")

            #expect(global.first?.text == "make test")
            #expect(scoped.first?.text == "make test")
            #expect(global.first?.contextCount == 2)
            #expect(scoped.first?.contextCount == 2)
            // Identical candidate rows, so identical feature mass and
            // priors. The global query (directory nil) weights every
            // row x1; the scoped query weights the /x row x3, so the
            // delta is exactly (3.0 - 1.0) x count.
            let globalScore = try #require(global.first?.score)
            let scopedScore = try #require(scoped.first?.score)
            #expect(abs((scopedScore - globalScore) - 2.0) < 1e-9)
        }
    }

    @Test func contextExcludesExitCodeAndHostMismatches() async throws {
        try await withStore { store, _ in
            await record(store, "git st")
            await record(store, "git push", exitCode: 1, previous: "git st")
            await record(store, "git pull", host: "other.example", previous: "git st")
            await record(store, "cargo build", previous: "git st")

            // Exit-0, host-less context: only rows recorded under it.
            let rows = await followUps(store, previous: "git st")
            #expect(rows.map(\.text) == ["cargo build"])
            #expect(rows.first?.contextCount == 1)
            #expect(rows.first?.contextTotal == 1)

            // A foreign host sees only its own rows, not host-less
            // ones.
            let remote = await followUps(store, previous: "git st", host: "other.example")
            #expect(remote.map(\.text) == ["git pull"])

            // Exit-code mismatch excludes the failing follow-up.
            let failing = await followUps(store, previous: "git st", exitCode: 1)
            #expect(failing.map(\.text) == ["git push"])
        }
    }

    @Test func contextCountsFeedTheGate() async throws {
        try await withStore { store, _ in
            await record(store, "git st", directory: "/x")
            await record(store, "git push", directory: "/x", previous: "git st")
            await record(store, "git push", directory: "/x", previous: "git st")
            await record(store, "cargo build", directory: "/x", previous: "git st")

            let rows = await followUps(store, previous: "git st", directory: "/x")
            #expect(rows.first?.text == "git push")
            #expect(rows.first?.contextCount == 2)
            #expect(rows.first?.contextTotal == 3)
            #expect(HistoryRecorder.meetsGate(count: 2, total: 3))
        }
    }

    @Test func featureMassBreaksScoreTies() async throws {
        try await withStore { store, _ in
            await record(store, "git st")
            await record(store, "git status", previous: "git st")
            await record(store, "cargo build", previous: "git st")

            // Equal transition mass and equal priors (frozen
            // timestamps, one use each): the candidate sharing features
            // with `git st` ranks first; feature overlap alone never
            // pools a candidate, it only orders within equal scores.
            let rows = await followUps(store, previous: "git st")
            #expect(rows.map(\.text).sorted() == ["cargo build", "git status"])
            #expect(rows.first?.text == "git status")
            let firstScore = try #require(rows.first?.score)
            let lastScore = try #require(rows.last?.score)
            #expect(firstScore == lastScore)
            #expect((rows.first?.featureMass ?? 0) > (rows.last?.featureMass ?? 0))
        }
    }

    @Test func acceptanceTipsTieBetweenIdenticalPeers() async throws {
        try await withStore { store, url in
            await record(store, "git st")
            // Identical context mass: one exit-0 and one exit-1 use per
            // candidate keeps the exit-0 transition rows at count 1
            // while use counts reach 2. Frozen timestamps, so score and
            // feature mass tie exactly and the strict comparison below
            // rides on the prior tie-break.
            await record(store, "git push", exitCode: 0, previous: "git st")
            await record(store, "git push", exitCode: 1, previous: "git st")
            await record(store, "git pull", exitCode: 0, previous: "git st")
            await record(store, "git pull", exitCode: 1, previous: "git st")

            // Accepting `git push` lifts its feedback rate from 0.5 to
            // the cap, strictly outranking `git pull`.
            let pushID = try #require(scalar(url, "SELECT id FROM command WHERE normalized = 'git push'"))
            await store.recordAcceptance(commandID: pushID)

            let rows = await followUps(store, previous: "git st")
            #expect(rows.first?.text == "git push")
        }
    }

    @Test func contextPrefixCandidateBeatsGloballyFrequentMatch() async throws {
        try await withStore { store, _ in
            await record(store, "make", directory: "/x")
            await record(store, "make test", directory: "/x", previous: "make")
            await record(store, "make test", directory: "/x", previous: "make")
            // Globally more frequent and more recent, but never a
            // `make` follow-up.
            let later = Self.frozenDate.addingTimeInterval(100)
            for _ in 0..<5 {
                await record(store, "make tea", directory: "/x", at: later)
            }

            // Tier 1 pools transitions only: `make tea` is absent.
            let tier1 = await store.contextPrefixCandidates(
                previous: "make", directory: "/x", host: nil, exitCode: 0,
                prefix: "make t", extractor: CommandFeatureExtractor.version, limit: 20)
            #expect(tier1.map(\.text) == ["make test"])
            #expect(tier1.first?.contextCount == 2)

            // The recency tier would rank `make tea` first — exactly
            // why the cascade tries tier 1 before it.
            let tier2 = await store.recentPrefixCandidates(prefix: "make t", directory: "/x", limit: 20)
            #expect(tier2.first?.text == "make tea")
        }
    }

    @Test func sameDirectoryOccurrenceOutranksNewerGlobalMatch() async throws {
        try await withStore { store, _ in
            await record(store, "git push", directory: "/x")
            await record(
                store, "git prune", directory: "/y",
                at: Self.frozenDate.addingTimeInterval(3_600))

            let rows = await store.recentPrefixCandidates(prefix: "git p", directory: "/x", limit: 20)
            #expect(rows.first?.text == "git push")
        }
    }

    // MARK: Upgrades and degradation

    @Test func olderDatabaseMigratesToV2WithoutLosingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("niftty-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.db")
        try seedV1Database(at: url)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(url: url)
        let disabled = await store.disabled
        #expect(!disabled)
        #expect(scalar(url, "PRAGMA user_version") == 2)
        #expect(scalar(url, "SELECT COUNT(*) FROM command") == 2)
        #expect(scalar(url, "SELECT id FROM command WHERE normalized = 'git stash'") == 20)
        #expect(scalar(url, "SELECT use_count FROM command WHERE id = 20") == 4)
        #expect(scalar(url, "SELECT success_count FROM command WHERE id = 20") == 3)
        #expect(scalar(url, "SELECT accepted_count FROM command WHERE id = 20") == 1)
        #expect(scalar(url, "SELECT COUNT(*) FROM feature") == 1)
        #expect(scalar(url, "SELECT COUNT(*) FROM meta WHERE key = 'saved'") == 1)
        #expect(scalar(url, "SELECT COUNT(*) FROM occurrence WHERE command_id = 20 AND directory = '/repo'") == 1)

        let rows = await followUps(store, previous: "git status", directory: "/repo")
        #expect(rows.first?.text == "git stash")
        #expect(rows.first?.contextCount == 3)
        let prefixRows = await store.recentPrefixCandidates(prefix: "git sta", directory: "/repo", limit: 20)
        #expect(prefixRows.first?.text == "git stash")

        // New observations must continue to update the old rows, not
        // create a second history after the schema change.
        await record(store, "git stash", directory: "/repo", previous: "git status")
        #expect(scalar(url, "SELECT use_count FROM command WHERE id = 20") == 5)
        #expect(scalar(url, "SELECT count FROM transition WHERE prev_id = 10 AND next_id = 20") == 4)
        await store.close()

        let reopened = HistoryStore(url: url)
        let reopenedDisabled = await reopened.disabled
        let reopenedRows = await followUps(reopened, previous: "git status", directory: "/repo")
        #expect(!reopenedDisabled)
        #expect(reopenedRows.first?.contextCount == 4)
        await reopened.close()
    }

    @Test func unversionedV1DatabaseIsNotWiped() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("niftty-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.db")
        try seedV1Database(at: url, version: 0)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(url: url)
        let disabled = await store.disabled
        #expect(!disabled)
        #expect(scalar(url, "PRAGMA user_version") == 2)
        #expect(scalar(url, "SELECT COUNT(*) FROM command") == 2)
        #expect(scalar(url, "SELECT count FROM transition WHERE prev_id = 10 AND next_id = 20") == 3)
        await store.close()
    }

    @Test func unversionedV2DatabaseIsNotWiped() async throws {
        let (store, url) = makeStore()
        await record(store, "git stash")
        await store.close()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try executeSQL(at: url, "PRAGMA user_version = 0")

        let reopened = HistoryStore(url: url)
        let disabled = await reopened.disabled
        #expect(!disabled)
        #expect(scalar(url, "PRAGMA user_version") == 2)
        #expect(scalar(url, "SELECT COUNT(*) FROM command") == 1)
        await reopened.close()
    }

    @Test func newerDatabaseIsLeftIntactByOlderBuild() async throws {
        let (store, url) = makeStore()
        await record(store, "git stash")
        await store.close()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try executeSQL(at: url, "PRAGMA user_version = 3")

        let olderBuild = HistoryStore(url: url)
        let disabled = await olderBuild.disabled
        #expect(disabled)
        #expect(scalar(url, "PRAGMA user_version") == 3)
        #expect(scalar(url, "SELECT COUNT(*) FROM command") == 1)
        await olderBuild.close()
    }

    @Test func failedMigrationRollsBackWithoutDeletingV1History() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("niftty-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("history.db")
        try seedV1Database(at: url)
        // Force a migration error after renaming the old transition
        // table. The entire upgrade must roll back on this path.
        try executeSQL(at: url, "CREATE TABLE occurrence (incompatible TEXT)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(url: url)
        let disabled = await store.disabled
        #expect(disabled)
        #expect(scalar(url, "PRAGMA user_version") == 1)
        #expect(scalar(url, "SELECT COUNT(*) FROM command") == 2)
        #expect(scalar(url, "SELECT count FROM transition WHERE prev_id = 10 AND next_id = 20") == 3)
        #expect(scalar(url, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'transition_v1'") == 0)
        await store.close()
    }

    /// Write a populated v1 database with `user_version = 1`.
    private func seedV1Database(at url: URL, version: Int = 1) throws {
        try executeSQL(at: url, """
            CREATE TABLE command (
              id INTEGER PRIMARY KEY,
              text TEXT NOT NULL,
              normalized TEXT NOT NULL UNIQUE,
              first_seen REAL NOT NULL,
              last_seen REAL NOT NULL,
              use_count INTEGER NOT NULL DEFAULT 1,
              success_count INTEGER NOT NULL DEFAULT 0,
              accepted_count INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE transition (
              prev_id INTEGER NOT NULL,
              next_id INTEGER NOT NULL,
              directory TEXT NOT NULL,
              count INTEGER NOT NULL,
              PRIMARY KEY (prev_id, next_id, directory)
            );
            CREATE TABLE feature (
              command_id INTEGER NOT NULL,
              extractor INTEGER NOT NULL,
              hash INTEGER NOT NULL,
              weight REAL NOT NULL,
              PRIMARY KEY (command_id, extractor, hash)
            ) WITHOUT ROWID;
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO command (id, text, normalized, first_seen, last_seen, use_count, success_count, accepted_count)
              VALUES (10, 'git status', 'git status', 1700000000, 1700000000, 7, 6, 2),
                     (20, 'git stash', 'git stash', 1700000000, 1700000100, 4, 3, 1);
            INSERT INTO transition (prev_id, next_id, directory, count) VALUES (10, 20, '/repo', 3);
            INSERT INTO feature (command_id, extractor, hash, weight)
              VALUES (10, \(CommandFeatureExtractor.version), 42, 1.0);
            INSERT INTO meta (key, value) VALUES ('saved', 'yes');
            PRAGMA user_version = \(version);
            """)
    }

    private func executeSQL(at url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close_v2(db)
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
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
        var rows = await store.topCandidates(
            previous: "ls", directory: nil, host: nil, exitCode: 0,
            extractor: CommandFeatureExtractor.version, limit: 5)
        #expect(rows.isEmpty)
        rows = await store.contextPrefixCandidates(
            previous: "ls", directory: nil, host: nil, exitCode: 0, prefix: "l",
            extractor: CommandFeatureExtractor.version, limit: 5)
        #expect(rows.isEmpty)
        rows = await store.recentPrefixCandidates(prefix: "l", directory: nil, limit: 5)
        #expect(rows.isEmpty)
        await store.recordAcceptance(commandID: 1)
        await store.close()
    }
}
