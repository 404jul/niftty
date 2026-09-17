import AppKit
import SwiftUI

/// The Keybinds page in the graphical settings editor. Edits the real
/// Ghostty keybind configuration: every change is validated by the same
/// parser the terminal uses, and applying writes `keybind =` lines to the
/// config file.
struct KeybindsPage: View {
    @ObservedObject var model: KeybindsModel

    @State private var editingRow: KeybindsModel.Row?
    @State private var addingBinding = false
    @State private var confirmResetAll = false

    private var filteredRows: [KeybindsModel.Row] {
        let query = model.filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.rows }
        return model.rows.filter { row in
            row.trigger.localizedCaseInsensitiveContains(query) ||
                row.actions.joined(separator: " ")
                    .localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.resetAllPending { resetAllBanner }
            if let error = model.error { errorBanner(error) }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredRows) { row in
                        KeybindRowView(model: model, row: row) {
                            editingRow = row
                        }
                        Divider()
                    }

                    if filteredRows.isEmpty && model.rows.isEmpty &&
                        model.error == nil && !model.resetAllPending {
                        Text("No keybinds are active.")
                            .foregroundStyle(.secondary)
                            .padding()
                    }

                    advancedSection
                }
                .padding(.bottom, 16)
            }
        }
        .sheet(isPresented: $addingBinding) {
            KeybindEditorSheet(model: model, row: nil)
        }
        .sheet(item: $editingRow) { row in
            KeybindEditorSheet(model: model, row: row)
        }
        .alert("Reset all keybinds to defaults?", isPresented: $confirmResetAll) {
            Button("Reset", role: .destructive) { model.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every keybind = line will be removed from your config file so the built-in defaults apply. This is applied when you press Apply.")
        }
    }

    private var toolbar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by keys or action", text: $model.filter)
                .textFieldStyle(.plain)
            if !model.filter.isEmpty {
                Button {
                    model.filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button {
                addingBinding = true
            } label: {
                Label("Add", systemImage: "plus")
            }

            Button {
                confirmResetAll = true
            } label: {
                Label("Reset All to Defaults", systemImage: "arrow.uturn.backward")
            }
            .disabled(model.originalLines.isEmpty && !model.resetAllPending)
            .help("Remove every keybind line from the config file so the built-in defaults apply")
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var resetAllBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward")
            Text("All keybind lines will be removed from your config file when you press Apply, restoring the built-in defaults.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Undo") {
                model.reload()
            }
            .buttonStyle(.link)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(error)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background(.yellow.opacity(0.12))
    }

    @ViewBuilder
    private var advancedSection: some View {
        if !model.advanced.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.advanced) { line in
                        HStack(alignment: .firstTextBaseline) {
                            Text(line.raw.isEmpty ? "(empty)" : line.raw)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                            Text(line.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Advanced keybind lines (\(model.advanced.count))")
                    .font(.headline)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Row

private struct KeybindRowView: View {
    @ObservedObject var model: KeybindsModel
    let row: KeybindsModel.Row
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if row.removed {
                        Text(KeybindsModel.displayTrigger(row))
                            .strikethrough()
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(KeybindsModel.displayTrigger(row))
                            .font(.body.monospaced().weight(.medium))
                        Text(KeybindPretty.prettyTrigger(row.trigger))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if row.removed {
                        Text("Removed")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red.opacity(0.12))
                            .clipShape(Capsule())
                    } else if model.isModified(row) {
                        Text("Modified")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }

                    if !row.removed, model.isConflicting(row) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("These keys conflict with another binding; the last one in the config file wins")
                    }
                }

                if !row.removed {
                    Text(actionSummary)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if let docs = actionDocs, !docs.isEmpty {
                        Text(docs)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let table = row.table {
                        Text("key table: \(table)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }

                    if !row.removed, row.actions.count > 1 {
                        Text("Runs \(row.actions.count) chained actions")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if !row.removed, !row.flagsEqualDefault {
                        Text(flagsSummary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }


                }
            }

            Spacer()

            if row.removed {
                Button("Undo") { model.unremove(row.id) }
                    .buttonStyle(.link)
            } else {
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit this binding")

                Button {
                    model.reset(row.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(!model.isModified(row) && !model.hasDefaultOrigin(row))
                .help(model.hasDefaultOrigin(row)
                    ? "Restore the default for these keys"
                    : "Revert your edits to this binding")

                Button {
                    model.remove(row.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this binding")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var actionSummary: String {
        row.actions.joined(separator: " → ")
    }

    private var actionDocs: String? {
        let name = row.primaryAction.split(separator: ":").first.map(String.init)
            ?? row.primaryAction
        return model.actions.first { $0.name == name }?.summary
    }

    private var flagsSummary: String {
        var parts: [String] = []
        if row.flags.global { parts.append("global") }
        if row.flags.all { parts.append("all") }
        if !row.flags.consumed { parts.append("unconsumed") }
        if row.flags.performable { parts.append("performable") }
        return parts.joined(separator: ", ")
    }
}



// MARK: - Editor sheet

/// Editor for a single binding (or a new one). Validates through the real
/// Ghostty parser on every keystroke and offers recording the keys
/// directly from the keyboard.
private struct KeybindEditorSheet: View {
    @ObservedObject var model: KeybindsModel
    /// The row being edited, or nil for a new binding.
    let row: KeybindsModel.Row?

    @Environment(\.dismiss) private var dismiss

    @State private var trigger: String
    @State private var action: String
    @State private var flags: Ghostty.Keybinding.Flags
    @StateObject private var recorder = KeyRecorder()

    init(model: KeybindsModel, row: KeybindsModel.Row?) {
        self.model = model
        self.row = row
        _trigger = State(initialValue: row?.trigger ?? "")
        _action = State(initialValue: row.map { $0.primaryAction } ?? "ignore")
        _flags = State(initialValue: row?.flags ?? Ghostty.Keybinding.Flags())
    }

    /// A draft row carrying the sheet's current values, used for
    /// validation against the live model.
    private var draft: KeybindsModel.Row {
        KeybindsModel.Row(
            id: row?.id ?? UUID(),
            table: row?.table,
            trigger: trigger.trimmingCharacters(in: .whitespaces),
            actions: [action.trimmingCharacters(in: .whitespaces)],
            flags: flags,
            removed: false,
            origin: .new
        )
    }

    private var validation: KeybindsModel.Validation {
        model.validation(for: draft)
    }

    private var isChanged: Bool {
        guard let row else { return true }
        return trigger.trimmingCharacters(in: .whitespaces) != row.trigger ||
            action.trimmingCharacters(in: .whitespaces) != row.primaryAction ||
            flags != row.flags
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(row == nil ? "Add Keybind" : "Edit Keybind")
                    .font(.title3.bold())
                Spacer()
                if let table = row?.table {
                    Text("key table: \(table)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 16)

            Form {
                Section {
                    HStack {
                        TextField("cmd+shift+c", text: $trigger)
                            .font(.body.monospaced())
                            .textFieldStyle(.roundedBorder)
                            .disabled(recorder.isRecording)

                        Button {
                            if recorder.isRecording {
                                recorder.stop()
                            } else {
                                recorder.onRecord = { keys in trigger = keys }
                                recorder.start()
                            }
                        } label: {
                            Label(
                                recorder.isRecording ? "Press keys…" : "Record",
                                systemImage: recorder.isRecording
                                    ? "circle.fill" : "record.circle"
                            )
                        }
                    }

                    if recorder.isRecording {
                        Text("Press the key combination to bind. Esc cancels.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        validationText
                    }
                } header: {
                    Text("Keys")
                } footer: {
                    Text("Ghostty syntax: modifiers (cmd, ctrl, alt, shift), a key, and sequences joined with >. Example: cmd+shift+c")
                }

                Section {
                    TextField("copy_to_clipboard", text: $action)
                        .font(.body.monospaced())
                        .textFieldStyle(.roundedBorder)

                    if (row?.actions.count ?? 0) > 1 {
                        Text("This binding currently chains \(row?.actions.count ?? 0) actions; saving replaces the chain with the single action above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    actionSuggestions
                } header: {
                    Text("Action")
                } footer: {
                    Text("Action name with an optional parameter, e.g. goto_tab:2 or text:hello")
                }

                Section("Options") {
                    Toggle("Global (works system-wide)", isOn: $flags.global)
                    Toggle("All surfaces (forward to every terminal)", isOn: $flags.all)
                    Toggle("Performable (only when the action can run)", isOn: $flags.performable)
                    Toggle("Don't consume the key event", isOn: Binding(
                        get: { !flags.consumed },
                        set: { flags.consumed = !$0 }))
                }
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    recorder.stop()
                    dismiss()
                }
                Spacer()
                Button(row == nil ? "Add" : "Save") {
                    recorder.stop()
                    apply()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!validation.isValid || !isChanged)
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 480)
        .onDisappear { recorder.stop() }
    }

    @ViewBuilder
    private var validationText: some View {
        let value = validation
        if !value.isValid, let message = value.message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if let clash = model.conflictMessage(
            canonicalTrigger: value.canonicalTrigger,
            table: draft.table,
            excluding: draft.id)
        {
            Text(clash)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if let canonical = value.canonicalTrigger, canonical != draft.trigger {
            Text("Canonical form: \(canonical)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionSuggestions: some View {
        let query = action.trimmingCharacters(in: .whitespaces)
        let matches = query.isEmpty
            ? [Ghostty.KeybindActionInfo]()
            : model.actions.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                    $0.docs.localizedCaseInsensitiveContains(query)
            }
        // Don't suggest when the exact action is already entered.
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(matches.prefix(5)) { info in
                    Button {
                        action = info.name + parameterSuffix(for: info)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(info.name)
                                    .font(.callout.monospaced().weight(.medium))
                                if info.parameter == "required" {
                                    Text("needs a parameter")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                } else if info.parameter == "optional" {
                                    Text("optional parameter")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if !info.summary.isEmpty {
                                Text(info.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func parameterSuffix(for info: Ghostty.KeybindActionInfo) -> String {
        switch info.parameter {
        case "required": return ":"
        default: return ""
        }
    }

    private func apply() {
        let keys = trigger.trimmingCharacters(in: .whitespaces)
        let act = action.trimmingCharacters(in: .whitespaces)
        if let row {
            model.setTrigger(keys, for: row.id)
            model.setAction(act, for: row.id)
            model.setFlags({ f in f = flags }, for: row.id)
        } else {
            model.add(trigger: keys, action: act, flags: flags)
        }
    }
}

// MARK: - Key recorder

/// Records a key combination from the keyboard while active using a local
/// NSEvent monitor and converts it to Ghostty trigger syntax.
@MainActor
final class KeyRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    var onRecord: ((String) -> Void)?

    private var monitor: Any?

    /// The owner stops the recorder on disappear; the monitor holds a weak
    /// reference so an unstopped monitor is harmless.

    func start() {
        guard monitor == nil, !isRecording else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }

            // Esc cancels recording without binding.
            if event.keyCode == Self.escapeCode {
                self.stop()
                return nil
            }

            if let trigger = Self.trigger(for: event) {
                let value = trigger
                self.stop()
                self.onRecord?(value)
                return nil
            }

            // Modifier-only or unmappable keys: keep waiting.
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }

    private static let escapeCode: CGKeyCode = 53

    /// Convert a key-down event to Ghostty trigger syntax. Returns nil for
    /// keys that cannot be expressed.
    private static func trigger(for event: NSEvent) -> String? {
        var parts: [String] = []
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) { parts.append("super") }
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.option) { parts.append("alt") }
        if mods.contains(.shift) { parts.append("shift") }

        if let physical = physicalName(for: event.keyCode) {
            parts.append(physical)
            return parts.joined(separator: "+")
        }

        guard let chars = event.charactersIgnoringModifiers,
              let scalar = chars.unicodeScalars.first,
              chars.unicodeScalars.count == 1,
              scalar.isASCII,
              scalar.value > 0x20, // control characters can't be bound this way
              scalar != "\u{7f}"
        else { return nil }

        let key: String
        if mods.contains(.shift), scalar.properties.isAlphabetic {
            // Ghostty's canonical form keeps the lowercase codepoint and
            // expresses the shift in the modifiers.
            key = String(scalar).lowercased()
        } else {
            key = String(scalar)
        }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// Mac virtual key codes for keys that must be bound by their physical
    /// (W3C) name rather than the character they produce. Names must match
    /// the Key enum in src/input/key.zig.
    private static let physicalKeys: [UInt16: String] = [
        36: "enter",
        48: "tab",
        49: "space",
        51: "backspace",
        53: "escape",
        65: "numpad_decimal",
        67: "numpad_multiply",
        69: "numpad_add",
        71: "numpad_clear",
        75: "numpad_divide",
        76: "numpad_enter",
        78: "numpad_subtract",
        81: "numpad_equal",
        82: "numpad_0",
        83: "numpad_1",
        84: "numpad_2",
        85: "numpad_3",
        86: "numpad_4",
        87: "numpad_5",
        88: "numpad_6",
        89: "numpad_7",
        91: "numpad_8",
        92: "numpad_9",
        96: "f5",
        97: "f6",
        98: "f7",
        99: "f3",
        100: "f8",
        101: "f9",
        103: "f11",
        105: "f13",
        106: "f16",
        107: "f14",
        109: "f10",
        111: "f12",
        113: "f15",
        114: "insert",
        115: "home",
        116: "page_up",
        117: "delete",
        118: "f4",
        119: "end",
        120: "f2",
        121: "page_down",
        122: "f1",
        123: "arrow_left",
        124: "arrow_right",
        125: "arrow_down",
        126: "arrow_up"
    ]

    private static func physicalName(for keyCode: UInt16) -> String? {
        physicalKeys[keyCode]
    }
}

// MARK: - Pretty triggers

/// Renders a canonical Ghostty trigger as macOS-style key symbols for
/// display next to the raw syntax.
enum KeybindPretty {
    private static let modifiers: [String: String] = [
        "super": "⌘",
        "ctrl": "⌃",
        "alt": "⌥",
        "shift": "⇧"
    ]

    private static let keys: [String: String] = [
        "arrow_up": "↑",
        "arrow_down": "↓",
        "arrow_left": "←",
        "arrow_right": "→",
        "enter": "↩",
        "numpad_enter": "⌤",
        "backspace": "⌫",
        "delete": "⌦",
        "escape": "⎋",
        "tab": "⇥",
        "space": "space",
        "home": "↖",
        "end": "↘",
        "page_up": "⇞",
        "page_down": "⇟",
        "caps_lock": "⇪",
        "insert": "Ins",
        "print_screen": "PrtSc"
    ]

    static func prettyTrigger(_ trigger: String) -> String {
        let chords = trigger.split(separator: ">", omittingEmptySubsequences: false)
        return chords.map { prettyChord(String($0)) }.joined(separator: " › ")
    }

    private static func prettyChord(_ chord: String) -> String {
        let parts = chord.split(separator: "+", omittingEmptySubsequences: false)

        // A chord with no "+" is a bare key (possibly the "+" key itself).
        if parts.count <= 1 {
            if chord.isEmpty { return "+" }
            return prettyKey(chord)
        }

        var result = ""
        for part in parts.dropLast() {
            if let symbol = modifiers[String(part)] {
                result += symbol
            } else {
                result += part + "+"
            }
        }

        // An empty final component means the key is a literal "+".
        if let last = parts.last, !last.isEmpty {
            result += prettyKey(String(last))
        } else {
            result += "+"
        }
        return result
    }

    private static func prettyKey(_ key: String) -> String {
        if let symbol = keys[key] { return symbol }
        if key.count == 1 {
            let upper = key.uppercased()
            if upper != key { return upper }
            return key
        }
        if key.hasPrefix("f"), key.dropFirst().allSatisfy(\.isNumber) {
            return key.uppercased()
        }
        return key
    }
}
