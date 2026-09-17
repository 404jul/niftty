import AppKit
import GhosttyKit

/// The model behind the Keybinds page in the graphical settings editor.
///
/// The page edits the `keybind =` lines of the config file. The effective
/// binding state (defaults plus the user's lines) comes from the real
/// Ghostty parser through the C API, and every edit is validated through
/// the same parser before it can be applied. Lines that use syntax this
/// editor does not model (such as `keybind = clear`) are preserved
/// untouched.
final class KeybindsModel: ObservableObject {
    /// One editable binding: a trigger sequence mapped to one or more
    /// (chained) actions within an optional key table.
    struct Row: Identifiable {
        let id: UUID
        var table: String?
        /// Trigger text in Ghostty syntax. Canonical unless the user is
        /// mid-edit; validation canonicalizes before anything is saved.
        var trigger: String
        /// Full action strings; the first is the primary action and the
        /// remainder come from `chain =` lines.
        var actions: [String]
        var flags: Ghostty.Keybinding.Flags
        var removed: Bool
        let origin: Origin

        /// Where the row came from. This determines how saving treats it.
        enum Origin {
            /// Indices of the raw config lines (the binding plus any
            /// trailing `chain =` lines) that produced this row.
            case userLines(IndexSet, original: Parsed)
            /// A built-in default binding that no user line overrides.
            case `default`(Ghostty.Keybinding)
            /// Added in this session.
            case new
        }

        /// The parsed form of a `keybind =` line value.
        struct Parsed {
            var table: String?
            var trigger: String
            var actions: [String]
            var flags: Ghostty.Keybinding.Flags
        }

        var primaryAction: String { actions.first ?? "ignore" }

        var flagsEqualDefault: Bool {
            flags == Ghostty.Keybinding.Flags()
        }
    }

    /// A raw config line the editor does not model and leaves untouched.
    struct AdvancedLine: Identifiable {
        let id: Int
        let raw: String
        let note: String
    }

    @Published var rows: [Row] = []
    @Published var advanced: [AdvancedLine] = []
    @Published var filter = ""
    @Published var error: String?
    @Published private(set) var resetAllPending = false

    private(set) var actions: [Ghostty.KeybindActionInfo] = []
    private(set) var defaultBindings: [Ghostty.Keybinding] = []
    /// Raw values of every `keybind =` line in the config file, in order.
    private(set) var originalLines: [String] = []

    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    // MARK: - Loading

    func reload() {
        guard let ghostty = appDelegate?.ghostty else { return }
        do {
            let data = try ghostty.config.keybindData()
            let text = try String(contentsOfFile: ghostty.configFilePath, encoding: .utf8)
            let rawLines = Self.keybindLineValues(in: text)

            var newRows: [Row] = []
            var newAdvanced: [AdvancedLine] = []

            // Classify each raw line. Groups hold the line indices that
            // form one logical binding (a binding plus trailing chains).
            struct Group {
                var indices: [Int] = []
                var raws: [String] = []
                var parsed: Row.Parsed
            }

            var groups: [Group] = []
            for (index, raw) in rawLines.enumerated() {
                let value = raw.trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    newAdvanced.append(AdvancedLine(
                        id: index,
                        raw: raw,
                        note: "restores the default keybinds"
                    ))
                    continue
                }
                if value == "clear" {
                    newAdvanced.append(AdvancedLine(
                        id: index,
                        raw: raw,
                        note: "clears every keybind"
                    ))
                    continue
                }
                if value.hasPrefix("chain=") {
                    // A chain attaches to the most recent binding group.
                    if !groups.isEmpty, !value.isEmpty {
                        let parse = Ghostty.Config.parseKeybindLine(value)
                        if parse.ok, parse.chain == true,
                           let action = parse.actions?.first {
                            groups[groups.count - 1].indices.append(index)
                            groups[groups.count - 1].raws.append(raw)
                            groups[groups.count - 1].parsed.actions.append(action)
                            continue
                        }
                    }
                    newAdvanced.append(AdvancedLine(
                        id: index,
                        raw: raw,
                        note: "advanced chained-action syntax"
                    ))
                    continue
                }

                let (table, rest) = Self.splitTablePrefix(value)
                if let table, rest.isEmpty {
                    newAdvanced.append(AdvancedLine(
                        id: index,
                        raw: raw,
                        note: "clears the \(table) key table"
                    ))
                    continue
                }

                let parse = Ghostty.Config.parseKeybindLine(rest)
                guard parse.ok, parse.chain != true,
                      let trigger = parse.trigger,
                      let actions = parse.actions,
                      !actions.isEmpty
                else {
                    let message = parse.error ?? "not valid Ghostty keybind syntax"
                    newAdvanced.append(AdvancedLine(
                        id: index,
                        raw: raw,
                        note: "left untouched: \(message)"
                    ))
                    continue
                }

                groups.append(Group(
                    indices: [index],
                    raws: [raw],
                    parsed: Row.Parsed(
                        table: table,
                        trigger: trigger,
                        actions: actions,
                        flags: parse.flags ?? Ghostty.Keybinding.Flags()
                    )
                ))
            }

            // The last group for a given key owns the effective binding;
            // earlier duplicates are shadowed.
            var ownerByKey: [String: Int] = [:]
            for (index, group) in groups.enumerated() {
                let key = Self.key(table: group.parsed.table, trigger: group.parsed.trigger)
                ownerByKey[key] = index
            }
            var shadowed = Set<Int>()
            for (index, group) in groups.enumerated() {
                let key = Self.key(table: group.parsed.table, trigger: group.parsed.trigger)
                if ownerByKey[key] != index {
                    shadowed.insert(index)
                    if let raw = group.raws.first {
                        newAdvanced.append(AdvancedLine(
                            id: group.indices.first ?? index,
                            raw: raw,
                            note: "overridden by a later line with the same keys"
                        ))
                    }
                }
            }

            // Match effective bindings to groups. An `unbind` or `ignore`
            // line that removes/keeps a binding is reflected by whether the
            // effective binding exists.
            var groupForBindingKey: [String: Int] = [:]
            for (index, group) in groups.enumerated() {
                guard !shadowed.contains(index) else { continue }
                let key = Self.key(table: group.parsed.table, trigger: group.parsed.trigger)
                groupForBindingKey[key] = index
            }

            var claimedGroups = Set<Int>()
            for binding in data.bindings {
                let key = binding.key
                if let groupIndex = groupForBindingKey[key] {
                    claimedGroups.insert(groupIndex)
                    let group = groups[groupIndex]
                    newRows.append(Row(
                        id: UUID(),
                        table: binding.table,
                        trigger: binding.trigger,
                        actions: binding.actions,
                        flags: binding.flags,
                        removed: false,
                        origin: .userLines(IndexSet(group.indices), original: group.parsed)
                    ))
                } else {
                    newRows.append(Row(
                        id: UUID(),
                        table: binding.table,
                        trigger: binding.trigger,
                        actions: binding.actions,
                        flags: binding.flags,
                        removed: false,
                        origin: .default(binding)
                    ))
                }
            }

            // Groups no effective binding claimed: `unbind` lines (which
            // remove bindings) or lines whose effect was cancelled later
            // in the file. They stay visible but read-only.
            for (index, group) in groups.enumerated() {
                guard !shadowed.contains(index),
                      !claimedGroups.contains(index),
                      let raw = group.raws.first
                else { continue }
                let note: String
                if group.parsed.actions == ["unbind"] {
                    note = "disables the binding for these keys"
                } else {
                    note = "has no effect (cancelled by a later line)"
                }
                newAdvanced.append(AdvancedLine(
                    id: group.indices.first ?? index,
                    raw: raw,
                    note: note
                ))
            }


            // Shadowed and unparseable lines keep their file order in the
            // advanced section.
            newAdvanced.sort { $0.id < $1.id }

            actions = data.actions.sorted { $0.name < $1.name }
            defaultBindings = data.bindings.filter { $0.default }
            originalLines = rawLines
            rows = Self.sorted(newRows)
            advanced = newAdvanced
            resetAllPending = false
            canonicalKeyCache = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Row edits

    func binding(at id: UUID) -> Int? {
        rows.firstIndex { $0.id == id }
    }

    func setTrigger(_ trigger: String, for id: UUID) {
        guard let index = binding(at: id) else { return }
        rows[index].trigger = trigger.trimmingCharacters(in: .whitespaces)
        canonicalKeyCache = nil
    }

    func setAction(_ action: String, for id: UUID) {
        guard let index = binding(at: id) else { return }
        let trimmed = action.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        rows[index].actions = [trimmed]
        canonicalKeyCache = nil
    }

    func setFlags(_ transform: (inout Ghostty.Keybinding.Flags) -> Void, for id: UUID) {
        guard let index = binding(at: id) else { return }
        transform(&rows[index].flags)
        canonicalKeyCache = nil
    }

    func remove(_ id: UUID) {
        guard let index = binding(at: id) else { return }
        if case .new = rows[index].origin {
            rows.remove(at: index)
        } else {
            rows[index].removed = true
        }
        canonicalKeyCache = nil
    }

    func unremove(_ id: UUID) {
        guard let index = binding(at: id) else { return }
        rows[index].removed = false
        canonicalKeyCache = nil
    }

    /// Restore this binding to its default, or revert the session edit if
    /// no default exists for these keys.
    func reset(_ id: UUID) {
        guard let index = binding(at: id) else { return }
        switch rows[index].origin {
        case .userLines(_, let original):
            rows[index].removed = false
            canonicalKeyCache = nil
            if let def = defaultBindings.first(where: {
                $0.key == Self.key(table: original.table, trigger: original.trigger)
            }) {
                rows[index].actions = def.actions
                rows[index].flags = def.flags
            } else {
                rows[index].trigger = original.trigger
                rows[index].actions = original.actions
                rows[index].flags = original.flags
            }
        case .default(let binding):
            rows[index].removed = false
            canonicalKeyCache = nil
            rows[index].trigger = binding.trigger
            rows[index].actions = binding.actions
            rows[index].flags = binding.flags
        case .new:
            rows.remove(at: index)
        }
    }

    func add(trigger: String, action: String, flags: Ghostty.Keybinding.Flags) {
        rows.append(Row(
            id: UUID(),
            table: nil,
            trigger: trigger,
            actions: [action],
            flags: flags,
            removed: false,
            origin: .new
        ))
        canonicalKeyCache = nil
        rows = Self.sorted(rows)
    }

    /// Mark every user `keybind =` line for removal so the built-in
    /// defaults come back on apply.
    func resetAll() {
        // Rebuild the visible rows from the pure defaults so the user sees
        // exactly what applying will produce.
        rows = Self.sorted(defaultBindings.map { binding in
            Row(
                id: UUID(),
                table: binding.table,
                trigger: binding.trigger,
                actions: binding.actions,
                flags: binding.flags,
                removed: false,
                origin: .default(binding)
            )
        })
        canonicalKeyCache = nil
        advanced = []
        resetAllPending = true
    }

    // MARK: - Validation

    /// The validation state of a row's current trigger and primary action.
    struct Validation {
        var isValid: Bool
        var message: String?
        var canonicalTrigger: String?
    }

    func validation(for row: Row) -> Validation {
        let line = Self.renderLine(row)
        let parse = Ghostty.Config.parseKeybindLine(line)
        guard parse.ok, parse.chain != true, let trigger = parse.trigger else {
            return Validation(
                isValid: false,
                message: parse.error ?? "invalid keybind",
                canonicalTrigger: nil
            )
        }

        // Sequences cannot be global/all; the parser rejects that too but
        // keep the check local for a clearer message.
        let isSequence = row.trigger.contains(">")
        if isSequence && (row.flags.global || row.flags.all) {
            return Validation(
                isValid: false,
                message: "sequences cannot use global or all",
                canonicalTrigger: trigger
            )
        }


        return Validation(
            isValid: true,
            message: nil,
            canonicalTrigger: trigger
        )
    }

    /// Cached mapping of row id to canonical key (table + canonical
    /// trigger) for conflict detection. Computed lazily after edits.
    private var canonicalKeyCache: [UUID: String]?

    var canonicalKeys: [UUID: String] {
        if let canonicalKeyCache { return canonicalKeyCache }
        var result: [UUID: String] = [:]
        for row in rows where !row.removed {
            let parse = Ghostty.Config.parseKeybindLine(Self.renderLine(row))
            if parse.ok, let trigger = parse.trigger {
                result[row.id] = Self.key(table: row.table, trigger: trigger)
            }
        }
        canonicalKeyCache = result
        return result
    }

    /// Canonical keys used by more than one visible binding.
    var conflictingKeys: Set<String> {
        var seen: Set<String> = []
        var duplicates: Set<String> = []
        for key in canonicalKeys.values {
            if !seen.insert(key).inserted {
                duplicates.insert(key)
            }
        }
        return duplicates
    }

    /// True when another visible binding uses the same keys; Ghostty lets
    /// the last binding in the config file win.
    func isConflicting(_ row: Row) -> Bool {
        guard !row.removed else { return false }
        guard let own = canonicalKeys[row.id] else { return false }
        return conflictingKeys.contains(own)
    }

    /// Conflict message for a draft (not yet applied) row in the editor.
    func conflictMessage(
        canonicalTrigger: String?,
        table: String?,
        excluding excludeId: UUID?
    ) -> String? {
        guard let canonicalTrigger else { return nil }
        let ownKey = Self.key(table: table, trigger: canonicalTrigger)
        let keys = canonicalKeys
        let clash = rows.filter { row in
            guard !row.removed, row.id != excludeId else { return false }
            return keys[row.id] == ownKey
        }
        guard !clash.isEmpty else { return nil }
        return "These keys are also used by: " +
            clash.map { Self.displayTrigger($0) }.sorted().joined(separator: ", ")
    }

    var hasInvalidRows: Bool {
        rows.contains { row in
            guard !row.removed else { return false }
            return !validation(for: row).isValid
        }
    }

    var hasChanges: Bool {
        if resetAllPending { return originalLines.count > 0 }
        return rows.contains { row in
            switch row.origin {
            case .new:
                return !row.removed
            default:
                return row.removed || isModified(row)
            }
        }
    }

    func isModified(_ row: Row) -> Bool {
        switch row.origin {
        case .userLines(_, let original):
            return row.trigger != original.trigger
                || row.actions != original.actions
                || row.flags != original.flags
        case .default(let binding):
            return row.trigger != binding.trigger
                || row.actions != binding.actions
                || row.flags != binding.flags
        case .new:
            return true
        }
    }

    /// True when resetting this row restores a built-in default (as
    /// opposed to merely reverting a session edit).
    func hasDefaultOrigin(_ row: Row) -> Bool {
        switch row.origin {
        case .default:
            return false
        case .userLines:
            return defaultBindings.contains {
                $0.key == Self.key(table: row.table, trigger: row.trigger)
            }
        case .new:
            return false
        }
    }

    // MARK: - Saving

    /// The new multi-line value for the `keybind` setting, or nil when the
    /// keybinds were not touched. Untouched raw lines are preserved
    /// verbatim so user spellings (e.g. `cmd` vs `super`) survive.
    func pendingLines() -> [String]? {
        guard hasChanges else { return nil }
        if resetAllPending { return [] }

        var deleted = Set<Int>()
        var emitted: [String] = []

        for row in rows {
            switch row.origin {
            case .userLines(let indices, _):
                if row.removed || isModified(row) {
                    deleted.formUnion(indices)
                }
                if !row.removed && isModified(row) {
                    emitted.append(contentsOf: Self.renderAllLines(row))
                }

            case .default(let binding):
                if row.removed {
                    // Removing a default requires an explicit unbind;
                    // otherwise the default would come back.
                    emitted.append("\(binding.trigger)=unbind")
                } else if isModified(row) {
                    emitted.append(contentsOf: Self.renderAllLines(row))
                    if row.trigger != binding.trigger {
                        // Rebinding a default: the old keys must stop
                        // triggering the action.
                        emitted.append("\(binding.trigger)=unbind")
                    }
                }

            case .new:
                if !row.removed {
                    emitted.append(contentsOf: Self.renderAllLines(row))
                }
            }
        }

        var kept: [String] = []
        for (index, raw) in originalLines.enumerated() {
            guard !deleted.contains(index) else { continue }
            kept.append(raw)
        }
        return kept + emitted
    }

    /// The first `keybind =` line for a row (flags prefixes, table prefix,
    /// trigger, action). Chained actions are separate `chain =` lines.
    static func renderLine(_ row: Row) -> String {
        var result = ""
        if row.flags.global { result += "global:" }
        if row.flags.all { result += "all:" }
        if !row.flags.consumed { result += "unconsumed:" }
        if row.flags.performable { result += "performable:" }
        if let table = row.table { result += table + "/" }
        result += row.trigger
        result += "="
        result += row.primaryAction
        return result
    }

    static func renderAllLines(_ row: Row) -> [String] {
        var lines = [renderLine(row)]
        for action in row.actions.dropFirst() {
            lines.append("chain=\(action)")
        }
        return lines
    }

    // MARK: - Display helpers

    static func displayTrigger(_ row: Row) -> String {
        if let table = row.table {
            return "\(table)/\(row.trigger)"
        }
        return row.trigger
    }

    static func key(table: String?, trigger: String) -> String {
        if let table {
            return table + "/" + trigger
        }
        return trigger
    }

    static func sorted(_ rows: [Row]) -> [Row] {
        rows.sorted { lhs, rhs in
            switch (lhs.table, rhs.table) {
            case (nil, nil):
                return lhs.trigger.localizedCaseInsensitiveCompare(rhs.trigger) == .orderedAscending
            case (nil, _):
                return true
            case (_, nil):
                return false
            case (let l?, let r?):
                if l != r {
                    return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
                }
                return lhs.trigger.localizedCaseInsensitiveCompare(rhs.trigger) == .orderedAscending
            }
        }
    }

    /// All `keybind =` line values in the file, in order.
    static func keybindLineValues(in text: String) -> [String] {
        var result: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            guard name == "keybind" else { continue }
            let value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            result.append(value)
        }
        return result
    }

    /// Split a leading key table prefix (`name/`) off a line value,
    /// mirroring the rules of Keybinds.parseCLI in the Zig core.
    static func splitTablePrefix(_ value: String) -> (table: String?, rest: String) {
        // The table prefix ends at the first `/` before any `=`; without
        // an `=` the whole value is the head (a bare `name/` clears the
        // table).
        let eq = value.firstIndex(of: "=") ?? value.endIndex
        let head = value[..<eq]
        guard let slash = head.firstIndex(of: "/") else { return (nil, value) }
        let name = head[..<slash]
        guard !name.isEmpty else { return (nil, value) }
        guard !name.contains("+"), !name.contains(">") else { return (nil, value) }
        return (String(name), String(value[value.index(after: slash)...]))
    }
}
