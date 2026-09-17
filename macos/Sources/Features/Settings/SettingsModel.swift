import SwiftUI

struct SettingsFileEditor {
    static let beginMarker = "# BEGIN NIFTTY GRAPHICAL SETTINGS"
    static let endMarker = "# END NIFTTY GRAPHICAL SETTINGS"

    static func legacyOverrides(in text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(of: beginMarker),
              let end = lines[(begin + 1)...].firstIndex(of: endMarker)
        else { return [:] }

        var values: [String: [String]] = [:]
        for line in lines[(begin + 1)..<end] {
            guard let name = settingName(in: line),
                  let separator = line.firstIndex(of: "=")
            else { continue }

            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                values[name] = []
            } else {
                values[name, default: []].append(value)
            }
        }

        return values.mapValues { $0.joined(separator: "\n") }
    }

    static func replacingSettings(
        in text: String,
        values: [String: String],
        orderedNames: [String],
        removeNames: Set<String> = []
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        if let begin = lines.firstIndex(of: beginMarker),
           let end = lines[(begin + 1)...].firstIndex(of: endMarker) {
            lines.removeSubrange(begin...end)
            if begin < lines.count, lines[begin].isEmpty,
               begin > 0, lines[begin - 1].isEmpty {
                lines.remove(at: begin)
            }
        }

        if !removeNames.isEmpty {
            lines.removeAll { line in
                guard let name = settingName(in: line) else { return false }
                return removeNames.contains(name)
            }
        }
        let known = orderedNames.filter { values[$0] != nil && !removeNames.contains($0) }
        let extras = values.keys.filter {
            !orderedNames.contains($0) && !removeNames.contains($0)
        }.sorted()
        for name in known + extras {
            guard let value = values[name] else { continue }
            let items = value.components(separatedBy: "\n")
                .filter { !$0.isEmpty }
            // Value lines append (repeatables may appear multiple times). An
            // empty value writes one explicit reset (`name =`), which clears
            // repeatable lists and unsets plain keys.
            let replacement = items.isEmpty
                ? ["\(name) ="]
                : items.map { "\(name) = \($0)" }

            var firstMatch: Int?
            var index = 0
            while index < lines.count {
                guard settingName(in: lines[index]) == name else {
                    index += 1
                    continue
                }
                if firstMatch == nil {
                    firstMatch = index
                    lines.replaceSubrange(index...index, with: replacement)
                    index += replacement.count
                } else {
                    lines.remove(at: index)
                }
            }

            if firstMatch == nil {
                // Clearing a name that has no occurrence in this file: nothing
                // to clear, so write nothing.
                guard !items.isEmpty else { continue }
                if lines.last?.isEmpty == false { lines.append("") }
                lines.append(contentsOf: replacement)
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func settingName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              let separator = trimmed.firstIndex(of: "=")
        else { return nil }
        let name = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

final class SettingsModel: ObservableObject {
    struct Row: Identifiable {
        let metadata: Ghostty.ConfigEditorSetting
        let defaultDisplayValue: String
        var value: String

        var id: String { metadata.name }
        var summary: String {
            metadata.description.components(separatedBy: "\n\n").first ?? ""
        }
    }

    @Published var rows: [Row] = []
    @Published var search = ""
    @Published var selectedCategory = "Appearance"
    @Published var error: String?
    @Published var hasUnsavedChanges = false

    private weak var appDelegate: AppDelegate?
    private var legacyValues: [String: String] = [:]
    private var pendingValues: [String: String] = [:]
    private var restoredDefaults: Set<String> = []

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    var configPath: String { appDelegate?.ghostty.configFilePath ?? "" }

    var categories: [String] {
        Set(rows.map { Self.category(for: $0.metadata.name) }).sorted()
    }

    /// Categories for the sidebar: row categories plus the dedicated
    /// Shaders page.
    var sidebarCategories: [String] {
        var result = categories
        if let idx = result.firstIndex(of: "Appearance") {
            result.insert("Shaders", at: idx + 1)
        } else {
            result.append("Shaders")
        }
        return result
    }

    /// Rows for the detail pane. Browsing shows only the selected category;
    /// searching matches across every category.
    var filteredRows: [Row] {
        rows.filter { row in
            guard !search.isEmpty else {
                return Self.category(for: row.metadata.name) == selectedCategory
            }
            return row.metadata.name.localizedCaseInsensitiveContains(search) ||
                row.metadata.description.localizedCaseInsensitiveContains(search) ||
                row.value.localizedCaseInsensitiveContains(search)
        }
    }

    /// Search results grouped by category, in sidebar order.
    var searchResultsByCategory: [(category: String, rows: [Row])] {
        sidebarCategories.compactMap { category in
            let matches = filteredRows.filter {
                Self.category(for: $0.metadata.name) == category
            }
            return matches.isEmpty ? nil : (category, matches)
        }
    }

    func binding(for name: String) -> Binding<String> {
        Binding(
            get: { [weak self] in
                self?.rows.first(where: { $0.id == name })?.value ?? ""
            },
            set: { [weak self] value in self?.set(value, for: name) })
    }

    func set(_ value: String, for name: String) {
        guard let index = rows.firstIndex(where: { $0.id == name }) else { return }
        rows[index].value = value
        restoredDefaults.remove(name)
        // SwiftUI text fields fire their binding setter on focus/commit even
        // when the text is unchanged, so compare against the loaded config
        // value: an identical value is not a change, and reverting a value
        // back to the original clears its pending entry. Other keys' pending
        // entries are left alone.
        if value == rows[index].metadata.value {
            pendingValues.removeValue(forKey: name)
        } else {
            pendingValues[name] = value
        }
        hasUnsavedChanges = !pendingValues.isEmpty || !legacyValues.isEmpty ||
            !restoredDefaults.isEmpty
    }

    func isModified(_ name: String) -> Bool {
        pendingValues[name] != nil || restoredDefaults.contains(name)
    }

    func restoreDefault(_ name: String) {
        guard let index = rows.firstIndex(where: { $0.id == name }) else { return }
        // Drop the override on save so Ghostty uses in-memory defaults.
        // Writing defaultValue would re-serialize it and can round-trip wrong
        // (selection-word-chars trimming leading space).
        rows[index].value = rows[index].metadata.defaultValue
        pendingValues.removeValue(forKey: name)
        restoredDefaults.insert(name)
        hasUnsavedChanges = true
    }

    func reload() {
        guard let appDelegate else { return }
        do {
            let metadata = try appDelegate.ghostty.config.editorSettings()
            let text = try String(contentsOfFile: appDelegate.ghostty.configFilePath, encoding: .utf8)
            legacyValues = SettingsFileEditor.legacyOverrides(in: text)
            pendingValues.removeAll()
            restoredDefaults.removeAll()
            rows = metadata.map { setting in
                Row(
                    metadata: setting,
                    defaultDisplayValue: Self.defaultDisplayValue(for: setting, in: metadata),
                    value: setting.value)
            }
            if !sidebarCategories.contains(selectedCategory) {
                selectedCategory = sidebarCategories.first ?? "Appearance"
            }
            hasUnsavedChanges = !legacyValues.isEmpty
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func openConfigFile() {
        appDelegate?.ghostty.openConfigFile()
    }

    func openThemeList() {
        guard let ghostty = appDelegate?.ghostty else { return }
        guard let exe = Bundle.main.executableURL?.path else {
            error = "Niftty executable is unavailable"
            return
        }
        var config = Ghostty.SurfaceConfiguration()
        config.initialInput = "\(Ghostty.Shell.quote(exe)) +list-themes; exit\n"
        _ = TerminalController.newWindow(ghostty, withBaseConfig: config)
    }

    func save() {
        guard let appDelegate else { return }
        do {
            let path = appDelegate.ghostty.configFilePath
            let existing = try String(contentsOfFile: path, encoding: .utf8)
            var values = legacyValues.merging(pendingValues) { _, pending in pending }
            for name in restoredDefaults {
                values.removeValue(forKey: name)
            }
            let updated = SettingsFileEditor.replacingSettings(
                in: existing,
                values: values,
                orderedNames: rows.map(\.id),
                removeNames: restoredDefaults)

            try updated.write(toFile: path, atomically: true, encoding: .utf8)
            appDelegate.ghostty.reloadConfig()
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func defaultDisplayValue(
        for setting: Ghostty.ConfigEditorSetting,
        in settings: [Ghostty.ConfigEditorSetting]
    ) -> String {
        if !setting.defaultValue.isEmpty { return setting.defaultValue }
        if setting.name == "theme" {
            let background = settings.first { $0.name == "background" }?.defaultValue
            let foreground = settings.first { $0.name == "foreground" }?.defaultValue
            if let background, !background.isEmpty,
               let foreground, !foreground.isEmpty {
                return "Built-in (\(background) / \(foreground))"
            }
            return "Built-in"
        }
        return "Unset"
    }

    static func category(for name: String) -> String {
        if name.hasPrefix("font-") || name.hasPrefix("adjust-") ||
            name == "grapheme-width-method" || name.hasPrefix("freetype-") {
            return "Font"
        }
        if name.hasPrefix("window-") || name.hasPrefix("quick-terminal-") ||
            name.hasPrefix("resize-overlay") || name.hasPrefix("quit-after-last-window-closed") ||
            name.hasPrefix("tab-") || name.hasPrefix("split-") || name.hasPrefix("unfocused-split-") ||
            name == "maximize" || name == "fullscreen" || name == "title" ||
            name == "scrollbar" || name == "drag-handle" || name == "initial-window" ||
            name == "confirm-close-surface" || name == "undo-timeout" {
            return "Window"
        }
        if name.hasPrefix("macos-") { return "macOS" }
        if name.hasPrefix("gtk-") || name.hasPrefix("linux-") ||
            name == "class" || name == "x11-instance-name" || name == "async-backend" {
            return "Linux"
        }
        if name.hasPrefix("clipboard-") || name == "copy-on-select" { return "Clipboard" }
        if name.hasPrefix("ssh-") { return "SSH" }
        if name.hasPrefix("shell-") || name.hasPrefix("notify-on-command-finish") ||
            name == "command" || name == "initial-command" || name == "env" ||
            name == "input" || name == "wait-after-command" ||
            name == "abnormal-command-exit-runtime" || name == "working-directory" ||
            name == "command-palette-entry" {
            return "Shell"
        }
        if name.hasPrefix("mouse-") || name.hasPrefix("keybind") ||
            name == "key-remap" || name == "click-repeat-interval" ||
            name == "right-click-action" || name == "middle-click-action" ||
            name == "focus-follows-mouse" || name == "cursor-click-to-move" {
            return "Input"
        }
        if name.hasPrefix("background") || name.hasPrefix("foreground") ||
            name.contains("color") || name.hasPrefix("cursor-") || name == "theme" ||
            name.hasPrefix("palette") || name.hasPrefix("selection-") ||
            name.hasPrefix("search-") || name == "minimum-contrast" ||
            name.hasPrefix("custom-shader") || name == "faint-opacity" ||
            name == "alpha-blending" {
            return "Appearance"
        }
        if name.hasPrefix("auto-update") { return "Updates" }
        return "Terminal"
    }
}
