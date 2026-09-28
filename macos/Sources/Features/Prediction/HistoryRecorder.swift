import Foundation

/// Main-thread consumer of prediction observations that feeds the
/// durable `HistoryStore` and serves local candidates through the
/// engine's provider seam.
///
/// It subscribes to `.nifttyPredictionObservation` on the main thread
/// (the engine publishes there), tracks the last observed command per
/// surface as the transition source, and fire-and-forget records into
/// the store. `predict(_:)` is what the engine's provider closure
/// calls at each prompt: a deterministic, local-only cascade modeled
/// on Warp's autosuggestion pipeline minus the AI tier — context
/// transitions first, typed-prefix tiers second, declining (nil) on
/// any miss.
@MainActor
final class HistoryRecorder {
    /// Candidate ids are "history-<command row id>"; parsed back on
    /// acceptance.
    private static let candidateIDPrefix = "history-"

    private let store: HistoryStore

    /// Whether the prediction layer is currently enabled. Mutable: the
    /// prediction config can change at runtime, and the recorder must
    /// follow it or predictions stay dead (nothing recorded, nothing
    /// served) until the app restarts. Main-actor isolated like the
    /// rest of this type.
    private(set) var enabled: Bool
    private var observer: (any NSObjectProtocol)?
    private var closeObserver: (any NSObjectProtocol)?

    /// The most recently finished command per surface, from
    /// observations only. A new prompt context does not clear it: the
    /// previous command is exactly the transition source for whatever
    /// comes next. Entries are dropped when the surface closes.
    private struct LastCommand {
        let text: String
        let exitCode: Int32?
    }

    private var lastCommandBySurface: [UUID: LastCommand] = [:]

    init(store: HistoryStore, enabled: Bool) {
        self.store = store
        self.enabled = enabled
        observer = NotificationCenter.default.addObserver(
            forName: .nifttyPredictionObservation,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let event = notification.userInfo?[Notification.Name.PredictionEventKey]
                  as? PredictionEngine.Event
            else { return }
            // The engine publishes on the main thread; we asked for the
            // main queue, so the isolated state is directly reachable.
            MainActor.assumeIsolated {
                self.handle(event)
            }
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.nifttySurfaceClosed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let surfaceID = notification.object as? UUID
            else { return }
            MainActor.assumeIsolated {
                self.lastCommandBySurface[surfaceID] = nil
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    // MARK: Runtime configuration

    /// Follow the runtime prediction configuration. Disabling stops
    /// serving candidates and stops recording observations; re-enabling
    /// resumes both without needing a restart. Recorded command context
    /// is kept, so a re-enable can still predict from the command that
    /// last ran.
    func setEnabled(_ newValue: Bool) {
        guard newValue != enabled else { return }
        enabled = newValue
    }

    // MARK: Provider seam

    /// Rank history for the surface's state and return the best
    /// candidate, or nil to decline — a local-only cascade:
    ///
    /// - Empty prompt: follow-ups of the previous command through
    ///   context-matching transitions, confidence-gated
    ///   (`meetsGate`) and directory-validated.
    /// - Typed prefix: (1) context-transition follow-ups matching the
    ///   typed prefix under the current directory and host, then (2)
    ///   recent prefix matches, this directory first. The first
    ///   candidate that both token-suffix-matches the typed text and
    ///   validates wins.
    ///
    /// Validation (`validates`) resolves the candidate's relative
    /// paths against the shell's current directory, using the
    /// directories each command was recorded in as evidence of which
    /// words are paths; see there for the rules.
    ///
    /// Any miss declines: there is no completer or model fallback.
    func predict(_ context: PredictionEngine.PredictionContext) async -> PredictionEngine.Candidate? {
        guard enabled else { return nil }
        let typed = context.input
        let directory = context.localPath ?? context.remotePath
        // Remote (or unidentified) hosts have no local disk to
        // validate against.
        let isLocalContext = context.host != nil && context.remotePath == nil

        // Typed prefix: two local tiers, first suffix-matching and
        // valid candidate wins.
        if !typed.isEmpty {
            let normalizedTyped = ShellLexer.normalize(typed)
            guard !normalizedTyped.isEmpty else { return nil }

            // Tier 1: context transitions out of the previous command.
            // Transitions are stored under the follow-up command's own
            // directory and host, so match against where the prompt is
            // now (after a `cd`, not where the previous command ran).
            // An unknown exit code is recorded as 0 by `record`, so
            // query with 0: a NULL bind would never match any row.
            if let last = lastCommandBySurface[context.surfaceID] {
                let rows = await store.contextPrefixCandidates(
                    previous: last.text,
                    directory: directory,
                    host: context.host,
                    exitCode: last.exitCode ?? 0,
                    prefix: normalizedTyped,
                    extractor: CommandFeatureExtractor.version,
                    limit: 20)
                let recorded = await recordedDirectories(of: rows, host: context.host)
                if let match = Self.firstValidCandidate(
                    rows,
                    typed: typed,
                    directory: directory,
                    isLocalContext: isLocalContext,
                    recordedDirectories: recorded)
                {
                    return match
                }
            }

            // Tier 2: recent prefix matches, this directory first.
            let rows = await store.recentPrefixCandidates(
                prefix: normalizedTyped,
                directory: directory,
                limit: 20)
            let recorded = await recordedDirectories(of: rows, host: context.host)
            return Self.firstValidCandidate(
                rows,
                typed: typed,
                directory: directory,
                isLocalContext: isLocalContext,
                recordedDirectories: recorded)
        }

        // Empty prompt: follow-up of the command that just ran, behind
        // a confidence gate. Weak evidence declines instead of
        // guessing.
        guard let last = lastCommandBySurface[context.surfaceID] else { return nil }
        let rows = await store.topCandidates(
            previous: last.text,
            directory: directory,
            host: context.host,
            exitCode: last.exitCode ?? 0,
            extractor: CommandFeatureExtractor.version,
            limit: 20)
        guard let top = rows.first,
              Self.meetsGate(count: top.contextCount, total: top.contextTotal)
        else { return nil }
        let recorded = await recordedDirectories(of: rows, host: context.host)
        for row in rows {
            guard Self.validates(
                row.text,
                directory: directory,
                isLocalContext: isLocalContext,
                recordedDirectories: recorded[row.id] ?? [])
            else { continue }
            return PredictionEngine.Candidate(
                id: "\(Self.candidateIDPrefix)\(row.id)",
                text: row.text,
                source: row.source,
                confidence: Double(row.contextCount) / Double(max(row.contextTotal, 1)),
                metadata: ["commandID": String(row.id)]
            )
        }
        return nil
    }

    /// The directories each candidate row was recorded in on `host`,
    /// fetched in one store query per tier (none for an empty tier).
    private func recordedDirectories(
        of rows: [HistoryStore.CandidateRow], host: String?
    ) async -> [Int64: [String]] {
        guard !rows.isEmpty else { return [:] }
        return await store.occurrenceDirectories(commandIDs: rows.map(\.id), host: host)
    }

    /// The remaining suffix of `command` after the typed `typed`
    /// prefix, compared token-by-token so quoting and spacing
    /// differences in either text still match. A typed token the line
    /// has moved past — every token when the typed line ends in a
    /// separator, all but the last otherwise — must match the command
    /// token at the same position exactly (case-insensitively); only
    /// the trailing unterminated token may prefix-match, completing
    /// the partially-typed token (prepended without a space). When the
    /// typed line ends in a separator, the suggested text is the raw
    /// remainder of the stored command after the last matched token,
    /// so quoting and substitutions survive verbatim (matching happens
    /// on flattened tokens, insertion must not); commands whose
    /// matched tokens came from inside a substitution fall back to the
    /// flattened form. Returns nil when the tokens already match
    /// exactly (nothing to add) or any token fails to match.
    nonisolated static func suffix(of command: String, afterTyped typed: String) -> String? {
        let typedTokens = ShellLexer.tokens(typed)
        let located = ShellLexer.locatedTokens(command)
        let commandTokens = located.map(\.token)
        guard typedTokens.count <= commandTokens.count else { return nil }

        // A trailing separator terminates the final typed token: the
        // user left it behind, so nothing mid-token can complete and
        // the suggestion continues with the next whole command token
        // (the separator is already on screen).
        let terminated = typed.last?.isWhitespace ?? false

        var exact = typedTokens.count == commandTokens.count
        for (i, token) in typedTokens.enumerated() {
            let target = commandTokens[i].text
            if !terminated && i == typedTokens.count - 1 {
                guard target.lowercased().hasPrefix(token.text.lowercased()) else { return nil }
            } else {
                guard target.lowercased() == token.text.lowercased() else { return nil }
            }
            if target != token.text { exact = false }
        }
        if exact { return nil }

        if terminated {
            guard typedTokens.count < commandTokens.count else { return nil }
            let matched = located[..<typedTokens.count]
            // Raw remainder: the stored text after the last matched
            // token, so quotes and substitutions are suggested (and
            // therefore executed) exactly as they were recorded. Only
            // usable when every matched token is top-level; a token
            // from inside `$(...)` has no raw boundary to slice at.
            if matched.allSatisfy({ !$0.nested }) {
                let chars = Array(command)
                var idx = matched.last!.end
                while idx < chars.count, chars[idx].isWhitespace { idx += 1 }
                guard idx < chars.count else { return nil }
                return String(command[command.index(command.startIndex, offsetBy: idx)...])
            }
            return commandTokens[typedTokens.count...]
                .map(\.text)
                .joined(separator: " ")
        }

        let last = typedTokens.count - 1
        var suffix = String(
            commandTokens[last].text.dropFirst(typedTokens[last].text.count))
        if typedTokens.count < commandTokens.count {
            suffix += " " + commandTokens[typedTokens.count...]
                .map(\.text)
                .joined(separator: " ")
        }
        return suffix.isEmpty ? nil : suffix
    }

    /// A zero-state suggestion needs at least two runs as a follow-up
    /// and at least a quarter of the context pool; weaker evidence
    /// declines rather than guessing.
    nonisolated static func meetsGate(count: Int, total: Int) -> Bool {
        count >= 2 && Double(count) / Double(max(total, 1)) >= 0.25
    }

    /// Whether `text` can run where the prompt is: every word that
    /// names a file must resolve from the shell's current `directory`
    /// (the local or remote path), not from wherever the command was
    /// recorded. `recordedDirectories` are the directories the command
    /// ran in, used as evidence of which bare words are paths.
    ///
    /// Checked words are arguments (flags excluded) plus a command
    /// word containing `/`; env-assignment prefixes and redirection
    /// targets are skipped, as are words the shell would expand
    /// (`$`, globs, braces, backticks, `~user`), URLs, and scp-style
    /// `host:path` words. A word is a path when it is absolute or
    /// home-anchored, explicitly relative (`.`, `..`, `./x`, `../x`, a
    /// `cd`/`pushd` argument, or a command word like `bin/rails`), or —
    /// locally — exists under some recorded directory. A word merely
    /// containing `/` is a path only as a fallback: locally when no
    /// recorded directory is known, remotely always.
    ///
    /// - Local: absolute/home paths must exist; relative paths must
    ///   exist under `directory` and reject when it is unknown.
    ///   Non-path words (`status`, `origin/main`) pass — shell
    ///   functions and aliases would be false rejections.
    /// - Remote: there is no disk to check, so absolute/home paths
    ///   pass, and relative paths pass only when the command was
    ///   recorded in this very directory.
    nonisolated static func validates(
        _ text: String,
        directory: String?,
        isLocalContext: Bool,
        recordedDirectories: [String],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        let recorded = recordedDirectories.filter { !$0.isEmpty }
        let recordedHere = directory.map { current in
            recorded.contains(where: { trimmingTrailingSlash($0) == trimmingTrailingSlash(current) })
        } ?? false

        for word in checkedWords(text) {
            if word.text.hasPrefix("/") || word.text == "~" || word.text.hasPrefix("~/") {
                guard !isLocalContext || fileExists(expandTilde(word.text)) else { return false }
                continue
            }

            let explicit = word.isExplicitPath
                || word.text == "." || word.text == ".."
                || word.text.hasPrefix("./") || word.text.hasPrefix("../")
            let syntactic = word.text.contains("/")

            if isLocalContext {
                let isPath = explicit
                    || recorded.contains(where: { fileExists(joined($0, word.text)) })
                    || (syntactic && recorded.isEmpty)
                guard isPath else { continue }
                guard let directory, fileExists(joined(directory, word.text)) else { return false }
            } else {
                guard explicit || syntactic else { continue }
                guard recordedHere else { return false }
            }
        }
        return true
    }

    /// A word `validates` checks, with whether its position alone
    /// makes it a path: a command word containing `/`, or a
    /// `cd`/`pushd` argument.
    private struct CheckedWord {
        let text: String
        let isExplicitPath: Bool
    }

    /// The words of `text` that may name files, per simple command:
    /// operators start a new command, redirection targets are
    /// skipped, leading env assignments are skipped, the next word is
    /// the command word (kept only when it contains `/`), and the
    /// remaining non-flag words are arguments. Words the shell would
    /// expand, URLs, and scp-style words are dropped: they cannot be
    /// resolved as literal paths.
    private nonisolated static func checkedWords(_ text: String) -> [CheckedWord] {
        var words: [CheckedWord] = []
        var commandWord: String?
        var skipRedirectTarget = false
        for token in ShellLexer.tokens(text) {
            switch token.kind {
            case .op:
                commandWord = nil
                skipRedirectTarget = false
                continue
            case .redirect:
                // A complete fd duplication (`2>&1`) has no target word.
                skipRedirectTarget = !(token.text.contains("&")
                    && (token.text.last?.isNumber ?? false))
                continue
            case .word:
                if skipRedirectTarget {
                    skipRedirectTarget = false
                    continue
                }
            }

            let word = token.text
            let isExplicitPath: Bool
            if let commandWord {
                guard !word.hasPrefix("-") else { continue }
                isExplicitPath = commandWord == "cd" || commandWord == "pushd"
            } else {
                if CommandFeatureExtractor.isEnvAssignment(word) { continue }
                commandWord = word
                guard word.contains("/") else { continue }
                isExplicitPath = true
            }
            guard isLiteralPath(word) else { continue }
            words.append(CheckedWord(text: word, isExplicitPath: isExplicitPath))
        }
        return words
    }

    /// Whether `word` could be a literal path: nothing the shell
    /// expands (`$`, globs, braces, backticks, `~user`), not a URL,
    /// and not scp-style (a `:` before any `/`, as in `host:dir/x`).
    private nonisolated static func isLiteralPath(_ word: String) -> Bool {
        if word.contains(where: { "$*?[{`".contains($0) }) { return false }
        if word.hasPrefix("~"), word != "~", !word.hasPrefix("~/") { return false }
        if word.contains("://") { return false }
        if let colon = word.firstIndex(of: ":") {
            guard let slash = word.firstIndex(of: "/"), slash < colon else { return false }
        }
        return true
    }

    /// `word` resolved under `directory` by plain string joining.
    private nonisolated static func joined(_ directory: String, _ word: String) -> String {
        directory.hasSuffix("/") ? directory + word : directory + "/" + word
    }

    /// `path` without one trailing `/`, except for the root.
    private nonisolated static func trimmingTrailingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Expand a leading `~` to the current user's home directory.
    private nonisolated static func expandTilde(_ word: String) -> String {
        guard word.hasPrefix("~") else { return word }
        return FileManager.default.homeDirectoryForCurrentUser.path + word.dropFirst()
    }

    /// The first row with a remaining suffix after `typed` that also
    /// validates in the current directory, given each row's recorded
    /// directories.
    private static func firstValidCandidate(
        _ rows: [HistoryStore.CandidateRow],
        typed: String,
        directory: String?,
        isLocalContext: Bool,
        recordedDirectories: [Int64: [String]]
    ) -> PredictionEngine.Candidate? {
        for row in rows {
            guard let suffix = suffix(of: row.text, afterTyped: typed),
                  validates(
                    row.text,
                    directory: directory,
                    isLocalContext: isLocalContext,
                    recordedDirectories: recordedDirectories[row.id] ?? [])
            else { continue }
            return PredictionEngine.Candidate(
                id: "\(candidateIDPrefix)\(row.id)",
                text: suffix,
                source: row.source,
                confidence: nil,
                metadata: ["commandID": String(row.id)]
            )
        }
        return nil
    }

    // MARK: Observation handling

    private func handle(_ event: PredictionEngine.Event) {
        switch event {
        case .context:
            // The context is the *next* prompt; the previously observed
            // command stays as the transition source.
            break

        case .command(let observation):
            guard enabled else { return }
            let previous = lastCommandBySurface[observation.surfaceID]
            lastCommandBySurface[observation.surfaceID] = LastCommand(
                text: observation.command.text,
                exitCode: observation.command.exitCode)
            let store = self.store
            Task {
                await store.record(
                    command: observation.command.text,
                    exitCode: observation.command.exitCode,
                    startedAt: observation.command.startedAt,
                    finishedAt: observation.command.finishedAt,
                    host: observation.host,
                    directory: observation.localPath ?? observation.remotePath,
                    previousCommand: previous?.text,
                    previousExitCode: previous?.exitCode
                )
            }

        case .outcome(let outcome):
            guard enabled,
                  outcome.kind == .accepted,
                  outcome.source == "history",
                  outcome.candidateID.hasPrefix(Self.candidateIDPrefix),
                  let commandID = Int64(outcome.candidateID.dropFirst(Self.candidateIDPrefix.count))
            else { return }
            let store = self.store
            Task {
                await store.recordAcceptance(commandID: commandID)
            }
        }
    }
}
