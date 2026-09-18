import Foundation
import GhosttyKit
import os

private let predictionLogger = Logger(subsystem: "com.niftty.app", category: "prediction")
/// The app-scoped engine for Niftty's inline prediction layer.
///
/// The engine owns no history and runs no models. It translates core
/// prediction events (prompt-ready, command-started, command-finished,
/// candidate accepted/dismissed) into typed values, drives the
/// replaceable async provider at OSC 133 prompt-ready boundaries, injects
/// candidates back into core through the C API, and publishes every
/// context, command observation, and candidate outcome through the single
/// ``Notification.Name.nifttyPredictionObservation`` notification.
///
/// Threading: all entry points are called on the main thread (the Ghostty
/// action callback is dispatched there via appTick) and the class is not
/// annotated because the surrounding App layer predates strict
/// concurrency. The provider closure runs concurrently and must be
/// Sendable; its result is delivered back to the main thread before it
/// touches engine state.
final class PredictionEngine {
    /// The context in which a prediction was requested. A context starts
    /// at each OSC 133 prompt-ready boundary and is identified by the
    /// core-side revision.
    struct PredictionContext: Sendable {
        let surfaceID: UUID
        let revision: UInt64

        /// The host the shell is running on. Local machines report the
        /// local host name; remotes (e.g. an SSH session) report nil
        /// because the host cannot be identified without probing.
        let host: String?

        /// The local working directory reported by the shell, if any.
        let localPath: String?

        /// The remote working directory reported by a shell on a
        /// non-local host, if any.
        let remotePath: String?

        /// The foreground PID bound to the remote pwd report, if any.
        let remoteSessionPID: Int?
    }

    /// An observed shell command execution, assembled from a started
    /// command line and its finish event.
    struct CommandObservation: Sendable {
        struct Command: Sendable {
            let text: String
            let startedAt: Date
            let finishedAt: Date
            let exitCode: Int32?
            let duration: TimeInterval
        }

        let command: Command
        let surfaceID: UUID
        let host: String?
        let localPath: String?
        let remotePath: String?
        let remoteSessionPID: Int?
    }

    /// A prediction candidate produced by a provider.
    struct Candidate: Sendable {
        let id: String
        let text: String
        let source: String
        let confidence: Double?
        let metadata: [String: String]
    }

    /// The outcome of a candidate that reached the terminal layer.
    struct PredictionOutcome: Sendable {
        enum Kind: Sendable {
            /// The candidate was accepted for display by core.
            case presented
            /// The user accepted the candidate; its text was inserted.
            case accepted
            /// Core dismissed the candidate because its context ended.
            case dismissed
            /// A newer candidate for the same surface replaced this one.
            case replaced
            /// Core rejected the submission (e.g. a stale revision).
            case rejectedStale
        }

        let kind: Kind
        let candidateID: String
        let source: String
        let surfaceID: UUID
        let revision: UInt64

        /// Provider latency in seconds, for presented/rejected outcomes.
        var providerLatency: TimeInterval?

        /// Inserted UTF-8 byte count, for accepted outcomes.
        var insertedBytes: Int?

        /// Inserted Unicode codepoint count, for accepted outcomes.
        var insertedCodepoints: Int?

        /// Why core dismissed the candidate, for dismissed outcomes.
        var dismissReason: DismissReason?
    }

    /// Why core dismissed a candidate. Mirrors
    /// ghostty_prediction_dismiss_reason_e.
    enum DismissReason: Sendable {
        case key
        case text
        case mouse
        case preedit
        case focus
        case secureInput
        case command
        case prompt
        case childExit
        case disabled

        init(cReason: ghostty_prediction_dismiss_reason_e) {
            switch cReason {
            case GHOSTTY_PREDICTION_DISMISS_KEY: self = .key
            case GHOSTTY_PREDICTION_DISMISS_TEXT: self = .text
            case GHOSTTY_PREDICTION_DISMISS_MOUSE: self = .mouse
            case GHOSTTY_PREDICTION_DISMISS_PREEDIT: self = .preedit
            case GHOSTTY_PREDICTION_DISMISS_FOCUS: self = .focus
            case GHOSTTY_PREDICTION_DISMISS_SECURE_INPUT: self = .secureInput
            case GHOSTTY_PREDICTION_DISMISS_COMMAND: self = .command
            case GHOSTTY_PREDICTION_DISMISS_PROMPT: self = .prompt
            case GHOSTTY_PREDICTION_DISMISS_CHILD_EXIT: self = .childExit
            case GHOSTTY_PREDICTION_DISMISS_DISABLED: self = .disabled
            default: self = .key
            }
        }
    }

    /// The event published through the observation notification.
    enum Event {
        case context(PredictionContext)
        case command(CommandObservation)
        case outcome(PredictionOutcome)
    }

    /// The provider seam: an async closure from a context to a candidate.
    /// Returning nil declines to predict for that context. This is the
    /// only integration point for a real prediction source; it is
    /// deliberately a closure rather than a protocol so it can be
    /// replaced at runtime.
    typealias Provider = @Sendable (PredictionContext) async -> Candidate?

    /// The active provider, if any. nil means prediction requests are
    /// declined and no candidates are ever injected.
    var provider: Provider? = nil

    /// An in-flight provider request for one surface.
    private struct PendingRequest {
        let token: UUID
        let context: PredictionContext
        let task: Task<Void, Never>
    }

    /// The live (submitted and displayed) candidate for one surface.
    /// Candidate metadata is retained only until its terminal outcome.
    private struct LiveCandidate {
        let candidate: Candidate
        let revision: UInt64
    }

    /// A started command awaiting its finish event.
    private struct StartedObservation {
        let text: String
        let startedAt: Date
        let revision: UInt64
        let host: String?
        let localPath: String?
        let remotePath: String?
        let remoteSessionPID: Int?
    }

    /// One in-flight provider request per surface. A new context for a
    /// surface cancels (logically supersedes) the previous one.
    private var pending: [UUID: PendingRequest] = [:]

    /// The live candidate per surface.
    private var live: [UUID: LiveCandidate] = [:]

    /// Started commands awaiting finish, per surface.
    private var started: [UUID: StartedObservation] = [:]

    init() {
        #if DEBUG
        // Debug preview source: a fixed candidate from the environment so
        // the prediction UI is inspectable without a real provider. The
        // same candidate is returned after each prompt-ready event.
        let preview = ProcessInfo.processInfo.environment["NIFFTY_PREDICTION_PREVIEW"] ?? ""
        if !preview.isEmpty {
            predictionLogger.info("preview provider installed text=\(preview, privacy: .public)")
            provider = { _ in
                Candidate(
                    id: "niftty-preview",
                    text: preview,
                    source: "preview",
                    confidence: nil,
                    metadata: [:]
                )
            }
        } else {
            predictionLogger.info("no preview provider: NIFFTY_PREDICTION_PREVIEW unset")
        }
        #endif
    }

    // MARK: Events from core

    /// A shell prompt became ready (OSC 133 B): start a new prediction
    /// context and request a candidate for it.
    func promptReady(_ surface: Ghostty.SurfaceView, revision: UInt64) {
        predictionLogger.info("prompt ready surface=\(surface.id) revision=\(revision)")

        // A new context supersedes any in-flight request for this surface.
        cancelPending(surface.id)

        let context = Self.makeContext(surface, revision: revision)
        post(.context(context))

        guard let provider else { return }
        let token = UUID()
        let startedAt = Date()
        let task = Task { [weak self, weak surface] in
            let candidate = await provider(context)
            let latency = Date().timeIntervalSince(startedAt)
            // Deliver on the main thread; all engine state is main-only.
            await MainActor.run {
                self?.submit(
                    surface,
                    token: token,
                    context: context,
                    candidate: candidate,
                    latency: latency
                )
            }
        }
        pending[surface.id] = PendingRequest(
            token: token,
            context: context,
            task: task
        )
    }

    /// A command started (OSC 133 C) with the decoded command line. The
    /// prediction context is invalidated by core, so any in-flight
    /// request for the surface is superseded.
    func commandStarted(_ surface: Ghostty.SurfaceView, command: String, revision: UInt64) {
        cancelPending(surface.id)
        started[surface.id] = StartedObservation(
            text: command,
            startedAt: Date(),
            revision: revision,
            host: Self.host(for: surface),
            localPath: surface.pwd,
            remotePath: surface.remotePwd?.path,
            remoteSessionPID: surface.remotePwd?.sessionPID
        )
    }

    /// A command finished; assemble and publish the observation.
    func commandFinished(
        _ surface: Ghostty.SurfaceView,
        exitCode: Int32,
        durationNs: UInt64
    ) {
        guard let s = started.removeValue(forKey: surface.id) else { return }
        let observation = CommandObservation(
            command: .init(
                text: s.text,
                startedAt: s.startedAt,
                finishedAt: Date(),
                exitCode: exitCode >= 0 ? exitCode : nil,
                duration: Double(durationNs) / 1_000_000_000
            ),
            surfaceID: surface.id,
            host: s.host,
            localPath: s.localPath,
            remotePath: s.remotePath,
            remoteSessionPID: s.remoteSessionPID
        )
        post(.command(observation))
    }

    /// The visible candidate was accepted by the user.
    func candidateAccepted(
        _ surface: Ghostty.SurfaceView,
        revision: UInt64,
        insertedBytes: UInt32,
        insertedCodepoints: UInt32
    ) {
        guard let current = live[surface.id], current.revision == revision else { return }
        live[surface.id] = nil
        post(outcome: PredictionOutcome(
            kind: .accepted,
            candidateID: current.candidate.id,
            source: current.candidate.source,
            surfaceID: surface.id,
            revision: revision,
            insertedBytes: Int(insertedBytes),
            insertedCodepoints: Int(insertedCodepoints)
        ))
    }

    /// The visible candidate was dismissed by core.
    func candidateDismissed(
        _ surface: Ghostty.SurfaceView,
        revision: UInt64,
        reason: DismissReason
    ) {
        guard let current = live[surface.id], current.revision == revision else { return }
        live[surface.id] = nil
        post(outcome: PredictionOutcome(
            kind: .dismissed,
            candidateID: current.candidate.id,
            source: current.candidate.source,
            surfaceID: surface.id,
            revision: revision,
            dismissReason: reason
        ))
    }

    /// The prediction configuration changed at runtime. Disabling
    /// prediction cancels all in-flight provider work; core clears
    /// candidates and rejects further submissions on its side.
    func configDidChange(predictionEnabled: Bool) {
        guard !predictionEnabled else { return }
        for key in pending.keys { cancelPending(key) }
    }

    // MARK: Internals

    /// Submit a provider result back into core. Runs on the main actor
    /// after the provider completes; does nothing if the request was
    /// superseded by a newer context or the surface went away.
    private func submit(
        _ surface: Ghostty.SurfaceView?,
        token: UUID,
        context: PredictionContext,
        candidate: Candidate?,
        latency: TimeInterval
    ) {
        // Superseded by a newer context (or cleared) for this surface.
        guard let request = pending[context.surfaceID],
              request.token == token
        else { return }
        pending[context.surfaceID] = nil

        guard let candidate else {
            predictionLogger.info("provider declined to predict")
            return
        }
        guard let surface, let cSurface = surface.surface else {
            predictionLogger.info("submit dropped: surface gone")
            return
        }

        predictionLogger.info("submitting candidate id=\(candidate.id, privacy: .public) revision=\(context.revision)")
        let id = Array(candidate.id.utf8)
        let text = Array(candidate.text.utf8)
        let accepted = id.withUnsafeBufferPointer { idBuf in
            text.withUnsafeBufferPointer { textBuf in
                ghostty_surface_prediction_set(
                    cSurface,
                    idBuf.baseAddress?.withMemoryRebound(
                        to: CChar.self,
                        capacity: idBuf.count
                    ) { $0 },
                    UInt(idBuf.count),
                    context.revision,
                    textBuf.baseAddress?.withMemoryRebound(
                        to: CChar.self,
                        capacity: textBuf.count
                    ) { $0 },
                    UInt(textBuf.count)
                )
            }
        }
        predictionLogger.info("core submission result accepted=\(accepted)")


        if accepted {
            // A prior live candidate for this surface is replaced.
            if let old = live[surface.id] {
                post(outcome: PredictionOutcome(
                    kind: .replaced,
                    candidateID: old.candidate.id,
                    source: old.candidate.source,
                    surfaceID: surface.id,
                    revision: old.revision
                ))
            }
            live[surface.id] = LiveCandidate(
                candidate: candidate,
                revision: context.revision
            )
            post(outcome: PredictionOutcome(
                kind: .presented,
                candidateID: candidate.id,
                source: candidate.source,
                surfaceID: surface.id,
                revision: context.revision,
                providerLatency: latency
            ))
        } else {
            post(outcome: PredictionOutcome(
                kind: .rejectedStale,
                candidateID: candidate.id,
                source: candidate.source,
                surfaceID: surface.id,
                revision: context.revision,
                providerLatency: latency
            ))
        }
    }

    /// Logically cancel (supersede) the in-flight request for a surface.
    /// The provider closure itself is not interruptible; its result is
    /// discarded by the token check in `submit`.
    private func cancelPending(_ surfaceID: UUID) {
        if let request = pending.removeValue(forKey: surfaceID) {
            request.task.cancel()
        }
    }

    /// Build a context for a surface. The host is the local host name
    /// for local shells and nil for remotes, where the host cannot be
    /// identified without probing.
    private static func makeContext(
        _ surface: Ghostty.SurfaceView,
        revision: UInt64
    ) -> PredictionContext {
        PredictionContext(
            surfaceID: surface.id,
            revision: revision,
            host: host(for: surface),
            localPath: surface.pwd,
            remotePath: surface.remotePwd?.path,
            remoteSessionPID: surface.remotePwd?.sessionPID
        )
    }

    private static func host(for surface: Ghostty.SurfaceView) -> String? {
        if surface.remotePwd != nil { return nil }
        return ProcessInfo.processInfo.hostName
    }

    private func post(_ event: Event) {
        NotificationCenter.default.post(
            name: .nifttyPredictionObservation,
            object: nil,
            userInfo: [Notification.Name.PredictionEventKey: event]
        )
    }

    private func post(outcome: PredictionOutcome) {
        post(.outcome(outcome))
    }
}
