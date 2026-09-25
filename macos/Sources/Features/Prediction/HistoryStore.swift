import Foundation
import SQLite3
import os

private let historyLogger = Logger(subsystem: "com.niftty.app", category: "prediction")


/// The SDK macro is a function-pointer cast that Swift cannot import;
/// -1 is SQLITE_TRANSIENT (sqlite copies the bound buffer).
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
/// Durable, actor-isolated store for observed shell commands.
///
/// One SQLite database under `~/.local/state/niftty/prediction/` holds
/// normalized commands, context transitions (scoped by directory,
/// host, and exit code), per-command last-run occurrences, and
/// per-extractor-version feature hashes. All access is serialized
/// by the actor; WAL mode plus a busy timeout keeps concurrent readers
/// (the sqlite3 CLI, tests) working. Every failure is logged and
/// degrades to a no-op — the store never takes the app down.
actor HistoryStore {
    /// One ranked candidate from history retrieval.
    struct CandidateRow: Sendable {
        let id: Int64
        let text: String
        /// Primary rank within a tier: weighted transition score
        /// (follow-ups), context transition count (context prefix),
        /// or prior (recent prefix).
        let score: Double
        /// Shared-feature mass with the previous command — a
        /// tie-breaker only, never enough to rank a candidate on its
        /// own.
        let featureMass: Double
        /// Use/recency/feedback (success and acceptance) prior.
        let prior: Double
        /// Raw SUM(count) over this candidate's context-matching
        /// transitions, and that sum across the whole context pool:
        /// the zero-state confidence-gate inputs.
        let contextCount: Int
        let contextTotal: Int
        let source: String

        /// Cascade ordering: primary score, then feature mass, then
        /// prior.
        static func ranksBefore(_ lhs: CandidateRow, _ rhs: CandidateRow) -> Bool {
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.featureMass != rhs.featureMass { return lhs.featureMass > rhs.featureMass }
            return lhs.prior > rhs.prior
        }
    }

    private enum StoreError: Error, CustomStringConvertible {
        case open(Int32)
        case exec(String, Int32)
        case step(String, Int32)
        case journalMode(String)
        case unsupportedVersion(Int)

        var description: String {
            switch self {
            case .open(let rc):
                "sqlite open failed rc=\(rc)"
            case .exec(let sql, let rc):
                "sqlite exec failed rc=\(rc) sql=\(sql)"
            case .step(let sql, let rc):
                "sqlite step failed rc=\(rc) sql=\(sql)"
            case .journalMode(let mode):
                "unexpected journal mode '\(mode)'"
            case .unsupportedVersion(let v):
                "database user_version \(v) is newer than supported"
            }
        }
    }

    /// Set when the database could not be opened or migrated. Every
    /// method becomes a no-op and `topCandidates` returns [].
    private(set) var disabled = false

    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// The database always lives under `~/.local/state/niftty/`
    /// regardless of XDG_STATE_HOME: the app cannot observe shell rc
    /// exports, so the path must match what the shell side computes
    /// from HOME (same reasoning as `SSHSession.stateURL`).
    static func defaultDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/niftty/prediction/history.db")
    }

    init(url: URL = HistoryStore.defaultDatabaseURL()) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let handle = try Self.openDatabase(at: url)
            db = handle
            try Self.configureDatabase(handle)
        } catch {
            historyLogger.error("history store disabled: \(String(describing: error), privacy: .public)")
            if let db { sqlite3_close_v2(db) }
            self.db = nil
            statements = [:]
            disabled = true
        }
    }

    deinit {
        for stmt in statements.values { sqlite3_finalize(stmt) }
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: Recording

    /// Record one executed command: upsert the normalized command, its
    /// context transition from `previousCommand` (directory, host,
    /// exit code), where it last ran (`occurrence`), and its feature
    /// rows for the current extractor version. Whitespace-only
    /// commands are skipped.
    func record(
        command: String,
        exitCode: Int32?,
        startedAt: Date,
        finishedAt: Date,
        host: String?,
        directory: String?,
        previousCommand: String?
    ) async {
        guard !disabled, db != nil else { return }
        let normalized = ShellLexer.normalize(command)
        guard !normalized.isEmpty else { return }

        do {
            try exec("BEGIN IMMEDIATE")
            do {
                let upsert = try prepare(Self.upsertCommandSQL)
                bindText(upsert, 1, command)
                bindText(upsert, 2, normalized)
                bindDouble(upsert, 3, startedAt.timeIntervalSince1970)
                bindDouble(upsert, 4, finishedAt.timeIntervalSince1970)
                bindInt(upsert, 5, exitCode == 0 ? 1 : 0)
                try stepDone(upsert, Self.upsertCommandSQL)

                guard let id = try commandID(forNormalized: normalized) else {
                    throw StoreError.step(Self.upsertCommandSQL, SQLITE_CORRUPT)
                }

                if let previousCommand {
                    let previous = ShellLexer.normalize(previousCommand)
                    if !previous.isEmpty, previous != normalized,
                       let prevID = try commandID(forNormalized: previous), prevID != id {
                        let transition = try prepare(Self.upsertTransitionSQL)
                        bindInt(transition, 1, prevID)
                        bindInt(transition, 2, id)
                        bindText(transition, 3, directory ?? "")
                        bindText(transition, 4, host ?? "")
                        bindInt(transition, 5, Int64(exitCode ?? 0))
                        bindDouble(transition, 6, finishedAt.timeIntervalSince1970)
                        try stepDone(transition, Self.upsertTransitionSQL)
                    }
                }

                let insertFeature = try prepare(Self.insertFeatureSQL)
                for feature in CommandFeatureExtractor.features(command) {
                    bindInt(insertFeature, 1, id)
                    bindInt(insertFeature, 2, Int64(CommandFeatureExtractor.version))
                    bindInt(insertFeature, 3, Int64(bitPattern: feature.hash))
                    bindDouble(insertFeature, 4, feature.weight)
                    try stepDone(insertFeature, Self.insertFeatureSQL)
                    // A statement that reached SQLITE_DONE must be
                    // reset before it can be rebound; prepare() would
                    // do this on its next checkout, but the loop binds
                    // directly.
                    sqlite3_reset(insertFeature)
                    sqlite3_clear_bindings(insertFeature)
                }

                let occurrence = try prepare(Self.upsertOccurrenceSQL)
                bindInt(occurrence, 1, id)
                bindText(occurrence, 2, directory ?? "")
                bindText(occurrence, 3, host ?? "")
                bindDouble(occurrence, 4, finishedAt.timeIntervalSince1970)
                try stepDone(occurrence, Self.upsertOccurrenceSQL)

                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        } catch {
            historyLogger.error("record failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Close the database and release all cached statements.
    /// Idempotent; every method becomes a no-op afterwards. Callers
    /// that delete the database files (tests) must close first —
    /// unlinking files out from under an open WAL connection is an
    /// API violation sqlite reports as corruption.
    func close() async {
        guard !disabled else { return }
        for stmt in statements.values { sqlite3_finalize(stmt) }
        statements = [:]
        if let db { sqlite3_close_v2(db) }
        self.db = nil
    }

    /// Count one user acceptance of a previously suggested command.
    func recordAcceptance(commandID: Int64) async {
        guard !disabled, db != nil else { return }
        do {
            let stmt = try prepare(Self.acceptanceSQL)
            bindInt(stmt, 1, commandID)
            try stepDone(stmt, Self.acceptanceSQL)
        } catch {
            historyLogger.error("recordAcceptance failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Retrieval

    /// Follow-up candidates for the command that just ran. The pool is
    /// the transitions out of `previous` that match the current
    /// context — exit code, host (or host-less rows), and directory —
    /// weighted 3.0 x count on an exact directory match and 1.0 x
    /// count otherwise, capped at 200 rows by weighted score. Feature
    /// mass and priors only order within equal scores. The previous
    /// command itself is never a candidate.
    func topCandidates(
        previous: String?,
        directory: String?,
        host: String?,
        exitCode: Int32?,
        extractor: Int,
        limit: Int
    ) async -> [CandidateRow] {
        guard !disabled, db != nil else { return [] }
        guard let previous else { return [] }
        let normalized = ShellLexer.normalize(previous)
        guard !normalized.isEmpty else { return [] }

        do {
            let stmt = try prepare(Self.topCandidatesSQL)
            bindTransitionContext(
                stmt, normalized: normalized, directory: directory,
                host: host, exitCode: exitCode)

            let scanned = try scanContextRows(stmt, sql: Self.topCandidatesSQL)
            guard !scanned.isEmpty else { return [] }
            let prevID = try commandID(forNormalized: normalized)
            let mass = try featureMass(
                ids: scanned.map(\.id), previousID: prevID, extractor: extractor)
            return finalize(scanned, featureMass: mass, limit: limit)
        } catch {
            historyLogger.error("topCandidates failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Prefix tier 1: follow-ups of the command that just ran whose
    /// normalized text starts with `prefix` (exact matches excluded —
    /// there is nothing left to suggest), ranked by context transition
    /// count, then feature mass, then priors.
    func contextPrefixCandidates(
        previous: String?,
        directory: String?,
        host: String?,
        exitCode: Int32?,
        prefix: String,
        extractor: Int,
        limit: Int
    ) async -> [CandidateRow] {
        guard !disabled, db != nil else { return [] }
        guard let previous, !prefix.isEmpty else { return [] }
        let normalized = ShellLexer.normalize(previous)
        guard !normalized.isEmpty else { return [] }

        do {
            let stmt = try prepare(Self.contextPrefixCandidatesSQL)
            bindTransitionContext(
                stmt, normalized: normalized, directory: directory,
                host: host, exitCode: exitCode)
            bindText(stmt, 5, prefix)

            let scanned = try scanContextRows(stmt, sql: Self.contextPrefixCandidatesSQL)
            guard !scanned.isEmpty else { return [] }
            let prevID = try commandID(forNormalized: normalized)
            let mass = try featureMass(
                ids: scanned.map(\.id), previousID: prevID, extractor: extractor)
            return finalize(scanned, featureMass: mass, limit: limit)
        } catch {
            historyLogger.error(
                "contextPrefixCandidates failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Prefix tier 2: every command whose normalized text starts with
    /// `prefix` (exact matches excluded), ordered by same-directory
    /// occurrence, then recency, then use count — entirely SQL-side,
    /// so rows are returned in query order without a Swift re-sort.
    func recentPrefixCandidates(
        prefix: String,
        directory: String?,
        limit: Int
    ) async -> [CandidateRow] {
        guard !disabled, db != nil else { return [] }
        guard !prefix.isEmpty else { return [] }

        do {
            let stmt = try prepare(Self.recentPrefixCandidatesSQL)
            bindText(stmt, 1, prefix)
            if let directory, !directory.isEmpty {
                bindText(stmt, 2, directory)
            } else {
                sqlite3_bind_null(stmt, 2)
            }

            var rows: [CandidateRow] = []
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                let prior = Self.prior(
                    useCount: sqlite3_column_int64(stmt, 2),
                    lastSeen: sqlite3_column_double(stmt, 3),
                    successCount: sqlite3_column_int64(stmt, 4),
                    acceptedCount: sqlite3_column_int64(stmt, 5))
                rows.append(CandidateRow(
                    id: sqlite3_column_int64(stmt, 0),
                    text: columnText(stmt, 1),
                    score: prior,
                    featureMass: 0,
                    prior: prior,
                    contextCount: 0,
                    contextTotal: 0,
                    source: "history"))
                rc = sqlite3_step(stmt)
            }
            sqlite3_reset(stmt)
            guard rc == SQLITE_DONE else {
                throw StoreError.step(Self.recentPrefixCandidatesSQL, rc)
            }
            return Array(rows.prefix(limit))
        } catch {
            historyLogger.error(
                "recentPrefixCandidates failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    // MARK: Retrieval helpers

    /// One row of the 8-column shape shared by both transition
    /// queries.
    private struct ContextRow {
        let id: Int64
        let text: String
        let useCount: Int64
        let lastSeen: Double
        let successCount: Int64
        let acceptedCount: Int64
        /// Weighted score (follow-up tier) or context count (prefix
        /// tier 1) — the tier's primary rank.
        let score: Double
        /// Raw SUM(count) across the candidate's context-matching
        /// transition rows.
        let rawCount: Int
    }

    /// Bind the context shared by both transition queries: previous
    /// command (?1), directory (?2 — NULL matches every row at 1.0),
    /// host (?3 — NULL matches only host-less rows), exit code (?4).
    private func bindTransitionContext(
        _ stmt: OpaquePointer,
        normalized: String,
        directory: String?,
        host: String?,
        exitCode: Int32?
    ) {
        bindText(stmt, 1, normalized)
        if let directory, !directory.isEmpty {
            bindText(stmt, 2, directory)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        if let host, !host.isEmpty {
            bindText(stmt, 3, host)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let exitCode {
            bindInt(stmt, 4, Int64(exitCode))
        } else {
            sqlite3_bind_null(stmt, 4)
        }
    }

    /// Step a context query to completion, then reset it.
    private func scanContextRows(
        _ stmt: OpaquePointer, sql: String
    ) throws -> [ContextRow] {
        var rows: [ContextRow] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            rows.append(ContextRow(
                id: sqlite3_column_int64(stmt, 0),
                text: columnText(stmt, 1),
                useCount: sqlite3_column_int64(stmt, 2),
                lastSeen: sqlite3_column_double(stmt, 3),
                successCount: sqlite3_column_int64(stmt, 4),
                acceptedCount: sqlite3_column_int64(stmt, 5),
                score: sqlite3_column_double(stmt, 6),
                rawCount: Int(sqlite3_column_int64(stmt, 7))))
            rc = sqlite3_step(stmt)
        }
        sqlite3_reset(stmt)
        guard rc == SQLITE_DONE else {
            throw StoreError.step(sql, rc)
        }
        return rows
    }

    /// Blend feature mass and priors into final rows ordered by
    /// (score, feature mass, prior).
    private func finalize(
        _ scanned: [ContextRow], featureMass: [Int64: Double], limit: Int
    ) -> [CandidateRow] {
        // The pool is capped at 200 rows, so summing in Swift is fine.
        let total = scanned.reduce(0) { $0 + $1.rawCount }
        var rows = scanned.map { s in
            CandidateRow(
                id: s.id,
                text: s.text,
                score: s.score,
                featureMass: featureMass[s.id] ?? 0,
                prior: Self.prior(
                    useCount: s.useCount,
                    lastSeen: s.lastSeen,
                    successCount: s.successCount,
                    acceptedCount: s.acceptedCount),
                contextCount: s.rawCount,
                contextTotal: total,
                source: "history")
        }
        rows.sort(by: CandidateRow.ranksBefore)
        return Array(rows.prefix(limit))
    }

    /// Shared-feature mass between each pooled command and the
    /// previous command, for the current extractor version — a
    /// tie-breaker signal only.
    private func featureMass(
        ids: [Int64], previousID: Int64?, extractor: Int
    ) throws -> [Int64: Double] {
        guard let previousID, !ids.isEmpty else { return [:] }
        let sql = Self.featureMassSQL(ids: ids)
        return try withStatement(sql) { stmt in
            bindInt(stmt, 1, Int64(extractor))
            bindInt(stmt, 2, previousID)
            var mass: [Int64: Double] = [:]
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                mass[sqlite3_column_int64(stmt, 0)] = sqlite3_column_double(stmt, 1)
                rc = sqlite3_step(stmt)
            }
            guard rc == SQLITE_DONE else {
                throw StoreError.step(sql, rc)
            }
            return mass
        }
    }

    // MARK: Scoring

    /// Use/recency/feedback prior shared by every retrieval tier.
    private static func prior(
        useCount: Int64, lastSeen: Double, successCount: Int64, acceptedCount: Int64
    ) -> Double {
        0.3 * log10(Double(max(useCount, 1)))
            + 0.2 * recencyDecay(lastSeen: lastSeen, now: Date().timeIntervalSince1970)
            + 0.2 * feedbackRate(
                successCount: successCount, acceptedCount: acceptedCount, useCount: useCount)
    }

    /// Exponential decay with a 14-day half-life: 1.0 when just seen,
    /// 0.5 after two weeks.
    private static func recencyDecay(lastSeen: Double, now: Double) -> Double {
        let ageDays = max(0, now - lastSeen) / 86_400
        return exp(-0.693_147_180_559_945 * ageDays / 14)
    }

    /// Positive-feedback rate. Acceptance is an additive success
    /// signal capped at one per use, so commands never accepted score
    /// exactly as they did under success-rate-only weighting and the
    /// suggestion threshold needs no retuning.
    private static func feedbackRate(successCount: Int64, acceptedCount: Int64, useCount: Int64) -> Double {
        guard useCount > 0 else { return 0 }
        let rate = (Double(successCount) + Double(acceptedCount)) / Double(useCount)
        return min(1, max(0, rate))
    }

    // MARK: SQLite plumbing

    private static let upsertCommandSQL = """
    INSERT INTO command (text, normalized, first_seen, last_seen, use_count, success_count, accepted_count)
    VALUES (?1, ?2, ?3, ?4, 1, ?5, 0)
    ON CONFLICT(normalized) DO UPDATE SET
        last_seen = excluded.last_seen,
        use_count = command.use_count + 1,
        success_count = command.success_count + excluded.success_count
    """

    private static let upsertTransitionSQL = """
    INSERT INTO transition (prev_id, next_id, directory, host, exit_code, count, last_seen)
    VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6)
    ON CONFLICT(prev_id, next_id, directory, host, exit_code) DO UPDATE SET
        count = transition.count + 1,
        last_seen = excluded.last_seen
    """

    private static let upsertOccurrenceSQL = """
    INSERT INTO occurrence (command_id, directory, host, last_seen)
    VALUES (?1, ?2, ?3, ?4)
    ON CONFLICT(command_id, directory, host) DO UPDATE SET
        last_seen = excluded.last_seen
    """

    private static let insertFeatureSQL = """
    INSERT OR IGNORE INTO feature (command_id, extractor, hash, weight)
    VALUES (?1, ?2, ?3, ?4)
    """

    private static let acceptanceSQL = """
    UPDATE command SET accepted_count = accepted_count + 1 WHERE id = ?1
    """

    private static let lookupIDSQL = "SELECT id FROM command WHERE normalized = ?1"

    /// Context-transition pool for the follow-up tier: transitions out
    /// of ?1 matching the current context (?2 directory, ?3 host, ?4
    /// exit code), weighted 3.0 on an exact directory match, capped at
    /// 200 rows by weighted score. The previous command itself is
    /// excluded.
    private static let topCandidatesSQL = """
    WITH pool AS (
        SELECT t.next_id AS cid,
               SUM(t.count * (CASE WHEN t.directory = ?2 THEN 3.0 ELSE 1.0 END)) AS score,
               SUM(t.count) AS raw_count
        FROM transition t
        WHERE t.prev_id = (SELECT id FROM command WHERE normalized = ?1)
          AND t.exit_code = ?4
          AND (t.host = ?3 OR t.host = '')
          AND (?2 IS NULL OR t.directory = '' OR t.directory = ?2)
          AND t.next_id != t.prev_id
        GROUP BY t.next_id
        ORDER BY score DESC
        LIMIT 200
    )
    SELECT c.id, c.text, c.use_count, c.last_seen, c.success_count, c.accepted_count,
           pool.score, pool.raw_count
    FROM pool JOIN command c ON c.id = pool.cid
    ORDER BY pool.score DESC
    """

    /// Prefix tier 1: the same context-transition pool, restricted to
    /// commands whose normalized text starts with ?5 (exact matches
    /// excluded), ordered by raw context count. The count is cast to
    /// REAL so the query shares the 8-column scan shape.
    private static let contextPrefixCandidatesSQL = """
    WITH pool AS (
        SELECT t.next_id AS cid, SUM(t.count) AS raw_count
        FROM transition t
        JOIN command c ON c.id = t.next_id
        WHERE t.prev_id = (SELECT id FROM command WHERE normalized = ?1)
          AND t.exit_code = ?4
          AND (t.host = ?3 OR t.host = '')
          AND (?2 IS NULL OR t.directory = '' OR t.directory = ?2)
          AND t.next_id != t.prev_id
          AND substr(c.normalized, 1, length(?5)) = ?5
          AND c.normalized != ?5
        GROUP BY t.next_id
        ORDER BY raw_count DESC
        LIMIT 200
    )
    SELECT c.id, c.text, c.use_count, c.last_seen, c.success_count, c.accepted_count,
           CAST(pool.raw_count AS REAL), pool.raw_count
    FROM pool JOIN command c ON c.id = pool.cid
    ORDER BY pool.raw_count DESC
    """

    /// Prefix tier 2: prefix-matched commands by same-directory
    /// occurrence (?2), then recency, then use count. The substr
    /// comparison is a scan, but history tables are small.
    private static let recentPrefixCandidatesSQL = """
    SELECT c.id, c.text, c.use_count, c.last_seen, c.success_count, c.accepted_count
    FROM command c
    LEFT JOIN occurrence o ON o.command_id = c.id AND o.directory = ?2
    WHERE substr(c.normalized, 1, length(?1)) = ?1
      AND c.normalized != ?1
    ORDER BY (o.command_id IS NOT NULL) DESC, COALESCE(o.last_seen, c.last_seen) DESC,
             c.use_count DESC
    LIMIT 200
    """

    /// Feature-overlap mass between the pooled command ids (inline IN
    /// list) and the previous command (?2), for extractor version ?1.
    /// The ids come straight from SQLite INTEGER columns and are
    /// interpolated as integers; the varying text means the statement
    /// is prepared one-shot rather than cached.
    private static func featureMassSQL(ids: [Int64]) -> String {
        let list = ids.map(String.init).joined(separator: ",")
        return """
        SELECT f.command_id, SUM(f.weight)
        FROM feature f
        WHERE f.extractor = ?1
          AND f.command_id IN (\(list))
          AND f.hash IN (
              SELECT p.hash FROM feature p
              WHERE p.extractor = ?1 AND p.command_id = ?2)
        GROUP BY f.command_id
        """
    }

    /// v2 schema. Existing command and feature rows survive upgrades;
    /// only the transition and occurrence layouts change from v1.
    private static let schemaV2 = """
    CREATE TABLE IF NOT EXISTS command (
      id INTEGER PRIMARY KEY,
      text TEXT NOT NULL,
      normalized TEXT NOT NULL UNIQUE,
      first_seen REAL NOT NULL,
      last_seen REAL NOT NULL,
      use_count INTEGER NOT NULL DEFAULT 1,
      success_count INTEGER NOT NULL DEFAULT 0,
      accepted_count INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS transition (
      prev_id INTEGER NOT NULL,
      next_id INTEGER NOT NULL,
      directory TEXT NOT NULL,
      host TEXT NOT NULL DEFAULT '',
      exit_code INTEGER NOT NULL,
      count INTEGER NOT NULL,
      last_seen REAL NOT NULL,
      PRIMARY KEY (prev_id, next_id, directory, host, exit_code)
    );
    CREATE TABLE IF NOT EXISTS occurrence (
      command_id INTEGER NOT NULL,
      directory TEXT NOT NULL,
      host TEXT NOT NULL DEFAULT '',
      last_seen REAL NOT NULL,
      PRIMARY KEY (command_id, directory, host)
    );
    CREATE TABLE IF NOT EXISTS feature (
      command_id INTEGER NOT NULL,
      extractor INTEGER NOT NULL,
      hash INTEGER NOT NULL,
      weight REAL NOT NULL,
      PRIMARY KEY (command_id, extractor, hash)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS feature_hash ON feature(extractor, hash);
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    """

    /// Preserve v1's commands, usage/acceptance counts and features,
    /// while supplying the context fields that v1 did not record. A
    /// v1 transition's exit code and host are unknown, so use the same
    /// host-less, exit-0 defaults used for unknown observations today.
    /// The successor's last-seen time is the best available timestamp.
    /// Everything, including user_version, commits together or rolls back.
    private static func migrateV1ToV2(_ db: OpaquePointer) throws {
        try execOn(db, "BEGIN IMMEDIATE")
        do {
            try execOn(db, "ALTER TABLE transition RENAME TO transition_v1")
            try execOn(db, schemaV2)
            try execOn(db, """
                INSERT INTO transition (prev_id, next_id, directory, host, exit_code, count, last_seen)
                SELECT t.prev_id, t.next_id, t.directory, '', 0, t.count, c.last_seen
                FROM transition_v1 t JOIN command c ON c.id = t.next_id;
                INSERT INTO occurrence (command_id, directory, host, last_seen)
                SELECT t.next_id, t.directory, '', MAX(c.last_seen)
                FROM transition_v1 t JOIN command c ON c.id = t.next_id
                GROUP BY t.next_id, t.directory;
                INSERT OR IGNORE INTO occurrence (command_id, directory, host, last_seen)
                SELECT id, '', '', last_seen FROM command;
                DROP TABLE transition_v1;
                PRAGMA user_version = 2;
                """)
            try execOn(db, "COMMIT")
        } catch {
            try? execOn(db, "ROLLBACK")
            throw error
        }
    }

    private static func createSchemaV2(_ db: OpaquePointer) throws {
        try execOn(db, "BEGIN IMMEDIATE")
        do {
            try execOn(db, schemaV2)
            // Version 0 may be a partially initialized v1 database
            // with commands but no transition table yet.
            try execOn(db, """
                INSERT OR IGNORE INTO occurrence (command_id, directory, host, last_seen)
                SELECT id, '', '', last_seen FROM command
                """)
            try execOn(db, "PRAGMA user_version = 2")
            try execOn(db, "COMMIT")
        } catch {
            try? execOn(db, "ROLLBACK")
            throw error
        }
    }

    /// Open the database file. Throws without leaving a handle behind.
    private static func openDatabase(at url: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            throw StoreError.open(rc)
        }
        return handle
    }

    /// Pragmas plus schema migration. Runs from init, before the actor
    /// is shared, on a connection the caller owns.
    private static func configureDatabase(_ db: OpaquePointer) throws {
        try execOn(db, "PRAGMA busy_timeout = 5000")
        try execOn(db, "PRAGMA synchronous = NORMAL")
        try execOn(db, "PRAGMA journal_size_limit = \(8 * 1024 * 1024)")
        let mode = try queryTextOn(db, "PRAGMA journal_mode = WAL")
        guard mode.lowercased() == "wal" else {
            throw StoreError.journalMode(mode)
        }
        let version = try queryIntOn(db, "PRAGMA user_version")
        switch version {
        case 0:
            // An interrupted initialization can leave either schema
            // with an unset user_version. Never overwrite its rows.
            let hasTransition = try queryIntOn(db, """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table' AND name = 'transition'
                """) != 0
            let alreadyV2 = try queryIntOn(db, """
                SELECT COUNT(*) FROM pragma_table_info('transition')
                WHERE name = 'exit_code'
                """) != 0
            if hasTransition && !alreadyV2 {
                try migrateV1ToV2(db)
            } else {
                try createSchemaV2(db)
            }
        case 1:
            try migrateV1ToV2(db)
        case 2:
            break
        case let v:
            throw StoreError.unsupportedVersion(v)
        }
    }

    private func commandID(forNormalized normalized: String) throws -> Int64? {
        let stmt = try prepare(Self.lookupIDSQL)
        bindText(stmt, 1, normalized)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else {
            sqlite3_reset(stmt)
            if rc == SQLITE_DONE { return nil }
            throw StoreError.step(Self.lookupIDSQL, rc)
        }
        let id = sqlite3_column_int64(stmt, 0)
        sqlite3_reset(stmt)
        return id
    }

    /// Cached prepared statement, reset and cleared for reuse.
    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] {
            sqlite3_reset(cached)
            sqlite3_clear_bindings(cached)
            return cached
        }
        guard let db else { throw StoreError.exec(sql, SQLITE_MISUSE) }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw StoreError.exec(sql, rc)
        }
        statements[sql] = stmt
        return stmt
    }

    /// Run `body` with a one-shot prepared statement, finalized on
    /// return. Used for SQL whose text embeds a varying id list —
    /// caching those would grow the statement cache without bound.
    private func withStatement<T>(
        _ sql: String, _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let db else { throw StoreError.exec(sql, SQLITE_MISUSE) }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw StoreError.exec(sql, rc)
        }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw StoreError.exec(sql, SQLITE_MISUSE) }
        try Self.execOn(db, sql)
    }

    private static func execOn(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        let text = message.map { String(cString: $0) } ?? ""
        if let message { sqlite3_free(message) }
        guard rc == SQLITE_OK else {
            historyLogger.error("sqlite: \(text, privacy: .public)")
            throw StoreError.exec(sql, rc)
        }
    }

    private static func queryTextOn(_ db: OpaquePointer, _ sql: String) throws -> String {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw StoreError.exec(sql, rc) }
        defer { sqlite3_finalize(stmt) }
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else { throw StoreError.step(sql, stepRC) }
        guard let c = sqlite3_column_text(stmt, 0) else { return "" }
        return String(cString: c)
    }

    private static func queryIntOn(_ db: OpaquePointer, _ sql: String) throws -> Int {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw StoreError.exec(sql, rc) }
        defer { sqlite3_finalize(stmt) }
        let stepRC = sqlite3_step(stmt)
        guard stepRC == SQLITE_ROW else { throw StoreError.step(sql, stepRC) }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func stepDone(_ stmt: OpaquePointer, _ sql: String) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw StoreError.step(sql, rc) }
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ text: String) {
        text.withCString { cString in
            _ = sqlite3_bind_text(stmt, index, cString, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        }
    }

    private func bindInt(_ stmt: OpaquePointer, _ index: Int32, _ value: Int64) {
        _ = sqlite3_bind_int64(stmt, index, value)
    }

    private func bindDouble(_ stmt: OpaquePointer, _ index: Int32, _ value: Double) {
        _ = sqlite3_bind_double(stmt, index, value)
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }
}
