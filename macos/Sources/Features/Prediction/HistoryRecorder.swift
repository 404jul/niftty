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
    private let enabled: Bool
    private var observer: (any NSObjectProtocol)?
    private var closeObserver: (any NSObjectProtocol)?

    /// The most recently finished command per surface, from
    /// observations only, with the execution context its transitions
    /// were recorded under. A new prompt context does not clear it:
    /// the previous command is exactly the transition source for
    /// whatever comes next. Entries are dropped when the surface
    /// closes.
    private struct LastCommand {
        let text: String
        let exitCode: Int32?
        let directory: String?
        let host: String?
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

    // MARK: Provider seam

    /// Rank history for the surface's state and return the best
    /// candidate, or nil to decline — a local-only cascade:
    ///
    /// - Empty prompt: follow-ups of the previous command through
    ///   context-matching transitions, confidence-gated
    ///   (`meetsGate`) and validated against the local disk.
    /// - Typed prefix: (1) context-transition follow-ups matching the
    ///   typed prefix, then (2) recent prefix matches, this directory
    ///   first. The first candidate that both token-suffix-matches
    ///   the typed text and validates wins.
    ///
    /// Any miss declines: there is no completer or model fallback.
    func predict(_ context: PredictionEngine.PredictionContext) async -> PredictionEngine.Candidate? {
        guard enabled else { return nil }
        let typed = context.input
        let directory = context.localPath ?? context.remotePath
        // Remote (or unidentified) hosts have no local disk to
        // validate against.
        let isLocalContext = context.host != nil && context.remotePath == nil

        // Typed prefix: two local tiers, first suffix-and-disk-valid
        // match wins.
        if !typed.isEmpty {
            let normalizedTyped = ShellLexer.normalize(typed)
            guard !normalizedTyped.isEmpty else { return nil }

            // Tier 1: context transitions out of the previous command,
            // matched under the context it was recorded in.
            if let last = lastCommandBySurface[context.surfaceID] {
                let rows = await store.contextPrefixCandidates(
                    previous: last.text,
                    directory: last.directory,
                    host: last.host,
                    exitCode: last.exitCode,
                    prefix: normalizedTyped,
                    extractor: CommandFeatureExtractor.version,
                    limit: 20)
                if let match = Self.firstValidCandidate(
                    rows, typed: typed, isLocalContext: isLocalContext)
                {
                    return match
                }
            }

            // Tier 2: recent prefix matches, this directory first.
            let rows = await store.recentPrefixCandidates(
                prefix: normalizedTyped,
                directory: directory,
                limit: 20)
            return Self.firstValidCandidate(
                rows, typed: typed, isLocalContext: isLocalContext)
        }

        // Empty prompt: follow-up of the command that just ran, behind
        // a confidence gate. Weak evidence declines instead of
        // guessing.
        guard let last = lastCommandBySurface[context.surfaceID] else { return nil }
        let rows = await store.topCandidates(
            previous: last.text,
            directory: directory,
            host: context.host,
            exitCode: last.exitCode,
            extractor: CommandFeatureExtractor.version,
            limit: 20)
        guard let top = rows.first,
              Self.meetsGate(count: top.contextCount, total: top.contextTotal)
        else { return nil }
        for row in rows {
            guard Self.validatesOnLocalDisk(row.text, isLocalContext: isLocalContext)
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

    /// The remaining suffix of `command` after the typed `typed`
    /// prefix, compared token-by-token so quoting and spacing
    /// differences in either text still match: every typed token must
    /// be a case-insensitive prefix of the command token at the same
    /// position. The suffix completes the partially-typed last token
    /// (prepended without a space) and appends the remaining command
    /// tokens, all in normalized form — quoting in the stored raw
    /// text is flattened. Returns nil when the tokens already match
    /// exactly (nothing to add) or any token fails to prefix-match.
    nonisolated static func suffix(of command: String, afterTyped typed: String) -> String? {
        let typedTokens = ShellLexer.tokens(typed)
        let commandTokens = ShellLexer.tokens(command)
        guard typedTokens.count <= commandTokens.count else { return nil }

        var exact = typedTokens.count == commandTokens.count
        for (i, token) in typedTokens.enumerated() {
            let target = commandTokens[i].text
            guard target.lowercased().hasPrefix(token.text.lowercased()) else { return nil }
            if target != token.text { exact = false }
        }
        if exact { return nil }

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

    /// Whether every path-like token of `text` exists on the local
    /// disk. Remote contexts have no local disk to check, so they
    /// always pass. Non-path tokens (command names, flags, plain
    /// arguments) are never validated — shell functions and aliases
    /// would be false rejections.
    nonisolated static func validatesOnLocalDisk(_ text: String, isLocalContext: Bool) -> Bool {
        guard isLocalContext else { return true }
        for token in ShellLexer.tokens(text) where isPathLike(token.text) {
            guard FileManager.default.fileExists(atPath: expandTilde(token.text)) else {
                return false
            }
        }
        return true
    }

    /// A token referencing a file somewhere: absolute, relative, or
    /// home-anchored.
    private nonisolated static func isPathLike(_ word: String) -> Bool {
        word.hasPrefix("/") || word.hasPrefix("./") || word.hasPrefix("../")
            || word.hasPrefix("~/") || word.contains("/")
    }

    /// Expand a leading `~` to the current user's home directory.
    private nonisolated static func expandTilde(_ word: String) -> String {
        guard word.hasPrefix("~") else { return word }
        return FileManager.default.homeDirectoryForCurrentUser.path + word.dropFirst()
    }

    /// The first row with a remaining suffix after `typed` that also
    /// validates on the local disk.
    private static func firstValidCandidate(
        _ rows: [HistoryStore.CandidateRow],
        typed: String,
        isLocalContext: Bool
    ) -> PredictionEngine.Candidate? {
        for row in rows {
            guard let suffix = suffix(of: row.text, afterTyped: typed),
                  validatesOnLocalDisk(row.text, isLocalContext: isLocalContext)
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
                exitCode: observation.command.exitCode,
                directory: observation.localPath ?? observation.remotePath,
                host: observation.host)
            let store = self.store
            Task {
                await store.record(
                    command: observation.command.text,
                    exitCode: observation.command.exitCode,
                    startedAt: observation.command.startedAt,
                    finishedAt: observation.command.finishedAt,
                    host: observation.host,
                    directory: observation.localPath ?? observation.remotePath,
                    previousCommand: previous?.text
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
