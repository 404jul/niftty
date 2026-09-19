import Foundation

/// Main-thread consumer of prediction observations that feeds the
/// durable `HistoryStore` and serves local candidates through the
/// engine's provider seam.
///
/// It subscribes to `.nifttyPredictionObservation` on the main thread
/// (the engine publishes there), tracks the last observed command per
/// surface as the transition source, and fire-and-forget records into
/// the store. `predict(_:)` is what the engine's provider closure
/// calls at each empty prompt.
@MainActor
final class HistoryRecorder {
    /// Candidates must clear this blended score to be suggested.
    private static let minimumScore = 1.0

    /// Confidence saturates at this score.
    private static let saturatingScore = 10.0

    /// Candidate ids are "history-<command row id>"; parsed back on
    /// acceptance.
    private static let candidateIDPrefix = "history-"

    private let store: HistoryStore
    private let enabled: Bool
    private var observer: (any NSObjectProtocol)?
    private var closeObserver: (any NSObjectProtocol)?

    /// The most recently finished command per surface, from
    /// observations only. A new prompt context does not clear it: the
    /// previous command is exactly the transition source for whatever
    /// comes next. Entries are dropped when the surface closes.
    private var lastCommandBySurface: [UUID: String] = [:]

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

    /// Rank history for the surface's last command and typed prefix and
    /// return the best candidate, or nil to decline. At an empty prompt
    /// this is the previous-command follow-up; once the user has typed,
    /// it is the remaining suffix of the best history match for the
    /// typed prefix.
    func predict(_ context: PredictionEngine.PredictionContext) async -> PredictionEngine.Candidate? {
        guard enabled else { return nil }
        let typed = context.input

        // Typed prefix: suggest the remaining suffix of the best match.
        // The query matches the normalized form (so quoting and spacing
        // differences in the typed text still match), while the suffix
        // is taken against the raw typed text so the completion is
        // always verbatim. Any history match is strong evidence, so no
        // score gate here.
        if !typed.isEmpty {
            let normalizedTyped = ShellLexer.normalize(typed)
            guard !normalizedTyped.isEmpty else { return nil }
            let rows = await store.topCandidates(
                previous: nil,
                directory: context.localPath ?? context.remotePath,
                extractor: CommandFeatureExtractor.version,
                prefix: normalizedTyped,
                limit: 20
            )
            let match = rows.lazy.compactMap { row -> PredictionEngine.Candidate? in
                guard let suffix = Self.suffix(of: row.text, after: typed) else {
                    return nil
                }
                return PredictionEngine.Candidate(
                    id: "\(Self.candidateIDPrefix)\(row.id)",
                    text: suffix,
                    source: row.source,
                    confidence: min(max(row.score, 0) / Self.saturatingScore, 1),
                    metadata: ["commandID": String(row.id)]
                )
            }
            return match.first
        }

        // Empty prompt: previous-command follow-up, score-gated.
        let rows = await store.topCandidates(
            previous: lastCommandBySurface[context.surfaceID],
            directory: context.localPath ?? context.remotePath,
            extractor: CommandFeatureExtractor.version,
            limit: 20
        )
        guard let top = rows.first, top.score >= Self.minimumScore else { return nil }
        return PredictionEngine.Candidate(
            id: "\(Self.candidateIDPrefix)\(top.id)",
            text: top.text,
            source: top.source,
            confidence: min(top.score / Self.saturatingScore, 1),
            metadata: ["commandID": String(top.id)]
        )
    }

    /// The remaining suffix of `command` after the typed `prefix`, or nil
    /// when the command does not start with the prefix. The match is
    /// case-insensitive so a prefix typed with different casing still
    /// completes to the stored form; the suffix is taken from the stored
    /// text so the completion is always verbatim.
    private static func suffix(of command: String, after prefix: String) -> String? {
        guard let range = command.range(
            of: prefix,
            options: [.caseInsensitive, .anchored]
        ) else { return nil }
        let suffix = String(command[range.upperBound...])
        return suffix.isEmpty ? nil : suffix
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
            lastCommandBySurface[observation.surfaceID] = observation.command.text
            let store = self.store
            Task {
                await store.record(
                    command: observation.command.text,
                    exitCode: observation.command.exitCode,
                    startedAt: observation.command.startedAt,
                    finishedAt: observation.command.finishedAt,
                    host: observation.host,
                    directory: observation.localPath ?? observation.remotePath,
                    previousCommand: previous
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
