import SwiftUI

extension Ghostty {
    /// Spotlight-style overlay shown centered on a surface while a key sequence
    /// (command chord, e.g. "super+k>z") is pending. Lists the commands available
    /// for the next key in the sequence, based on the effective keybind set, so
    /// user modifications to chords are reflected automatically. The overlay is
    /// purely passive: the terminal keeps keyboard focus and the core keeps
    /// matching continuation keys while it is visible.
    struct KeySequenceChordOverlay: View {
        let keySequence: [KeyboardShortcut]
        @ObservedObject var config: Ghostty.Config

        /// Decoded once per overlay presentation.
        @State private var data: Ghostty.KeybindEditorData?

        var body: some View {
            let candidates = Self.chordCandidates(
                bindings: data?.bindings ?? [],
                active: keySequence)

            VStack(alignment: .leading, spacing: 0) {
                header

                if !candidates.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(candidates, id: \.segment) { candidate in
                            row(candidate)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            .background(
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                    Rectangle()
                        .fill(config.backgroundColor)
                        .blendMode(.color)
                }
                .compositingGroup()
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .tertiaryLabelColor).opacity(0.75))
            )
            .shadow(radius: 32, x: 0, y: 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .allowsHitTesting(false)
            .onAppear {
                data = try? config.keybindData()
            }
        }

        /// The pressed prefix as keycaps plus the animated pending indicator.
        private var header: some View {
            HStack(spacing: 6) {
                ForEach(Array(keySequence.enumerated()), id: \.offset) { _, key in
                    KeyStateIndicator.KeyCap(key.description)
                }

                KeyStateIndicator.PendingIndicator(paused: false)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }

        private func row(_ candidate: ChordCandidate) -> some View {
            HStack(spacing: 10) {
                // Fixed-width column keeps titles aligned regardless of
                // keycap width.
                KeyStateIndicator.KeyCap(displayKey(for: candidate))
                    .frame(minWidth: 32, alignment: .center)

                if candidate.leader {
                    Text("More commands…")
                        .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: title(for: candidate))
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
        }

        /// Keycap label for a candidate. "⎋" reads as a mystery glyph to many
        /// users, so escape is spelled out.
        private func displayKey(for candidate: ChordCandidate) -> String {
            if candidate.segment == "escape" { return "Esc" }
            return KeybindPretty.prettyChord(candidate.segment)
        }

        /// Display title for a leaf candidate: the action catalog summary, with
        /// a friendlier label for the cancel action.
        private func title(for candidate: ChordCandidate) -> String {
            guard let action = candidate.action else { return candidate.segment }
            if action == "end_key_sequence" { return "Cancel pending chord" }

            // Parameterized actions (e.g. "goto_tab:2") document the bare name.
            let name = action.split(separator: ":", maxSplits: 1).first.map(String.init) ?? action
            if let info = data?.actions.first(where: { $0.name == name }), !info.summary.isEmpty {
                return info.summary
            }
            return action
        }

        // MARK: - Candidate model

        /// One follow-up key shown in the overlay: the next segment of one or
        /// more bindings matching the active sequence.
        struct ChordCandidate: Equatable {
            /// The next trigger segment in canonical Ghostty syntax (e.g. "z", "escape").
            let segment: String

            /// The action of a binding that completes at this segment, if any.
            let action: String?

            /// True when further bindings continue past this segment.
            let leader: Bool
        }

        /// True when two shortcuts match on key character and modifiers.
        /// `KeyboardShortcut` is only Equatable on macOS 14+, so compare parts.
        static func shortcutsEqual(_ a: KeyboardShortcut, _ b: KeyboardShortcut) -> Bool {
            a.key.character == b.key.character && a.modifiers == b.modifiers
        }

        /// Parse one canonical trigger segment (e.g. "super+k", "z", "escape")
        /// into a `KeyboardShortcut`. Returns nil for keys that can't be
        /// displayed; those bindings still work through core matching, they are
        /// just hidden from the overlay.
        static func segmentShortcut(_ segment: String) -> KeyboardShortcut? {
            var mods: EventModifiers = []
            let parts = segment.split(separator: "+", omittingEmptySubsequences: false)
            guard let last = parts.last, !last.isEmpty else { return nil }
            for part in parts.dropLast() {
                switch String(part) {
                case "super": mods.insert(.command)
                case "ctrl": mods.insert(.control)
                case "alt": mods.insert(.option)
                case "shift": mods.insert(.shift)
                default: return nil
                }
            }

            // Named keys, mirroring Ghostty.Input.keyToEquivalent.
            let key: KeyEquivalent
            switch String(last) {
            case "arrow_up": key = .upArrow
            case "arrow_down": key = .downArrow
            case "arrow_left": key = .leftArrow
            case "arrow_right": key = .rightArrow
            case "home": key = .home
            case "end": key = .end
            case "delete": key = .deleteForward
            case "page_up": key = .pageUp
            case "page_down": key = .pageDown
            case "escape": key = .escape
            case "enter": key = .return
            case "tab": key = .tab
            case "backspace": key = .delete
            case "space": key = .space
            default:
                // Canonical triggers store lowercase codepoints.
                guard last.count == 1, let ch = last.lowercased().first else { return nil }
                key = KeyEquivalent(ch)
            }
            return KeyboardShortcut(key, modifiers: mods)
        }

        /// Compute the follow-up candidates for the active sequence from the
        /// effective binding set: group bindings by their next trigger segment.
        static func chordCandidates(
            bindings: [Ghostty.Keybinding],
            active: [KeyboardShortcut]
        ) -> [ChordCandidate] {
            var nexts: [String: (action: String?, leader: Bool)] = [:]

            for binding in bindings {
                // The pending sequence is matched against the surface's main key
                // table; table-scoped bindings can't be its continuation.
                guard binding.table == nil else { continue }
                let segments = binding.trigger.components(separatedBy: ">")
                guard segments.count > active.count else { continue }

                var matches = true
                for (i, segment) in segments.prefix(active.count).enumerated() {
                    guard
                        let shortcut = segmentShortcut(segment),
                        shortcutsEqual(shortcut, active[i])
                    else {
                        matches = false
                        break
                    }
                }
                guard matches else { continue }

                let next = segments[active.count]
                if segments.count == active.count + 1 {
                    // A deeper binding wins over a leaf for the same segment.
                    if nexts[next]?.leader == true { continue }
                    if nexts[next] == nil {
                        nexts[next] = (binding.actions.first, false)
                    }
                } else {
                    nexts[next] = (nil, true)
                }
            }

            return nexts.map { segment, entry in
                ChordCandidate(segment: segment, action: entry.action, leader: entry.leader)
            }
            .sorted {
                if $0.leader != $1.leader { return !$0.leader }
                return $0.segment < $1.segment
            }
        }
    }
}
