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
/// normalized commands, prev→next transitions (scoped by directory),
/// and per-extractor-version feature hashes. All access is serialized
/// by the actor; WAL mode plus a busy timeout keeps concurrent readers
/// (the sqlite3 CLI, tests) working. Every failure is logged and
/// degrades to a no-op — the store never takes the app down.
actor HistoryStore {
    /// One ranked candidate from history retrieval.
    struct CandidateRow: Sendable {
        let id: Int64
        let text: String
        /// Blended SQL-side relevance score plus use/recency/feedback
        /// (success and acceptance) priors.
        let score: Double
        let source: String
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
    /// transition from `previousCommand` in `directory`, and its
    /// feature rows for the current extractor version. Whitespace-only
    /// commands are skipped. `host` is accepted for future host-scoped
    /// transitions but not persisted in v1.
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
                        bindDouble(transition, 4, finishedAt.timeIntervalSince1970)
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

    /// Rank stored commands as candidates. With no `prefix`, this ranks
    /// follow-ups for the command that just ran: one SQL query combines
    /// directory-weighted transitions (×3 on directory match, ×1 global)
    /// with shared-feature mass, capped at ~200 rows SQL-side; Swift then
    /// blends use/recency/feedback priors (successful runs and accepted
    /// suggestions) and sorts. The previous command itself is never a
    /// candidate.
    ///
    /// With a `prefix`, this instead ranks commands whose normalized
    /// text starts with the prefix by the same priors — the typed-prefix
    /// ("e" → "echo …") path. The prefix itself is matched against the
    /// normalized column, so quoting differences in the stored raw text
    /// do not hide matches.
    func topCandidates(
        previous: String?,
        directory: String?,
        extractor: Int,
        prefix: String? = nil,
        limit: Int
    ) async -> [CandidateRow] {
        guard !disabled, db != nil else { return [] }
        if let prefix, !prefix.isEmpty {
            return await topCandidatesByPrefix(prefix, limit: limit)
        }
        guard let previous else { return [] }
        let normalized = ShellLexer.normalize(previous)
        guard !normalized.isEmpty else { return [] }


        do {
            let stmt = try prepare(Self.topCandidatesSQL)
            bindText(stmt, 1, normalized)
            if let directory, !directory.isEmpty {
                bindText(stmt, 2, directory)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            bindInt(stmt, 3, Int64(extractor))

            var rows: [CandidateRow] = []
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let text = columnText(stmt, 1)
                let useCount = sqlite3_column_int64(stmt, 2)
                let lastSeen = sqlite3_column_double(stmt, 3)
                let successCount = sqlite3_column_int64(stmt, 4)
                let sqlScore = sqlite3_column_double(stmt, 6)
                let acceptedCount = sqlite3_column_int64(stmt, 5)
                let prior =
                    0.3 * log10(Double(max(useCount, 1)))
                    + 0.2 * Self.recencyDecay(
                        lastSeen: lastSeen, now: Date().timeIntervalSince1970)
                    + 0.2 * Self.feedbackRate(
                        successCount: successCount,
                        acceptedCount: acceptedCount,
                        useCount: useCount)
                rows.append(CandidateRow(
                    id: id,
                    text: text,
                    score: sqlScore + prior,
                    source: "history"))
                rc = sqlite3_step(stmt)
            }
            sqlite3_reset(stmt)
            guard rc == SQLITE_DONE else {
                throw StoreError.step(Self.topCandidatesSQL, rc)
            }

            rows.sort { $0.score > $1.score }
            return Array(rows.prefix(limit))
        } catch {
            historyLogger.error("topCandidates failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Rank commands whose normalized text starts with `prefix` by the
    /// use/recency/feedback priors. Exact matches (nothing left to
    /// suggest) are excluded.
    private func topCandidatesByPrefix(_ prefix: String, limit: Int) async -> [CandidateRow] {
        do {
            let stmt = try prepare(Self.prefixCandidatesSQL)
            bindText(stmt, 1, prefix)

            var rows: [CandidateRow] = []
            var rc = sqlite3_step(stmt)
            while rc == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let text = columnText(stmt, 1)
                let useCount = sqlite3_column_int64(stmt, 2)
                let lastSeen = sqlite3_column_double(stmt, 3)
                let successCount = sqlite3_column_int64(stmt, 4)
                let acceptedCount = sqlite3_column_int64(stmt, 5)
                let prior =
                    0.3 * log10(Double(max(useCount, 1)))
                    + 0.2 * Self.recencyDecay(
                        lastSeen: lastSeen, now: Date().timeIntervalSince1970)
                    + 0.2 * Self.feedbackRate(
                        successCount: successCount,
                        acceptedCount: acceptedCount,
                        useCount: useCount)
                rows.append(CandidateRow(
                    id: id,
                    text: text,
                    score: prior,
                    source: "history"))
                rc = sqlite3_step(stmt)
            }
            sqlite3_reset(stmt)
            guard rc == SQLITE_DONE else {
                throw StoreError.step(Self.prefixCandidatesSQL, rc)
            }

            rows.sort { $0.score > $1.score }
            return Array(rows.prefix(limit))
        } catch {
            historyLogger.error("topCandidatesByPrefix failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    // MARK: Scoring

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
    INSERT INTO transition (prev_id, next_id, directory, count, last_seen)
    VALUES (?1, ?2, ?3, 1, ?4)
    ON CONFLICT(prev_id, next_id, directory) DO UPDATE SET
        count = transition.count + 1,
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

    /// Transition scores and feature-overlap mass, pooled and capped at
    /// 200 rows by SQL-side score, excluding the previous command
    /// itself.
    private static let topCandidatesSQL = """
    WITH trans AS (
        SELECT t.next_id AS cid,
               SUM(t.count * (CASE WHEN t.directory = ?2 THEN 3.0 ELSE 1.0 END)) AS score
        FROM transition t
        WHERE t.prev_id = (SELECT id FROM command WHERE normalized = ?1)
          AND (?2 IS NULL OR t.directory = '' OR t.directory = ?2)
        GROUP BY t.next_id
    ),
    feat AS (
        SELECT f.command_id AS cid, SUM(f.weight) AS score
        FROM feature f
        WHERE f.extractor = ?3
          AND f.hash IN (
              SELECT p.hash FROM feature p
              WHERE p.extractor = ?3
                AND p.command_id = (SELECT id FROM command WHERE normalized = ?1))
        GROUP BY f.command_id
    ),
    pool AS (
        SELECT cid, SUM(score) AS sqlscore
        FROM (
            SELECT cid, score FROM trans
            UNION ALL
            SELECT cid, score FROM feat
        )
        WHERE cid != (SELECT id FROM command WHERE normalized = ?1)
        GROUP BY cid
        ORDER BY sqlscore DESC
        LIMIT 200
    )
    SELECT c.id, c.text, c.use_count, c.last_seen, c.success_count, c.accepted_count, pool.sqlscore
    FROM pool JOIN command c ON c.id = pool.cid
    ORDER BY pool.sqlscore DESC
    """

    /// Prefix matches by prior mass, excluding exact matches: once the
    /// typed line is the whole command there is nothing left to suggest.
    /// The substr comparison is a scan, but history tables are small.
    private static let prefixCandidatesSQL = """
    SELECT id, text, use_count, last_seen, success_count, accepted_count
    FROM command
    WHERE substr(normalized, 1, length(?1)) = ?1
      AND normalized != ?1
    ORDER BY use_count DESC, last_seen DESC
    LIMIT 200
    """

    /// v1 schema. Future versions migrate forward from `user_version`.
    private static let schemaV1 = """
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
      count INTEGER NOT NULL,
      PRIMARY KEY (prev_id, next_id, directory)
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
            try execOn(db, schemaV1)
            try execOn(db, "PRAGMA user_version = 1")
        case 1:
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
