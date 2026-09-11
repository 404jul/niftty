import SwiftUI

struct SettingsFileEditor {
    static let beginMarker = "# BEGIN NIFTTY GRAPHICAL SETTINGS"
    static let endMarker = "# END NIFTTY GRAPHICAL SETTINGS"

    static func overrides(in text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(of: beginMarker),
              let end = lines[(begin + 1)...].firstIndex(of: endMarker)
        else { return [:] }

        var values: [String: [String]] = [:]
        for line in lines[(begin + 1)..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  let separator = trimmed.firstIndex(of: "=")
            else { continue }

            let name = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            if value.isEmpty {
                values[name] = []
            } else {
                values[name, default: []].append(value)
            }
        }

        return values.mapValues { $0.joined(separator: "\n") }
    }

    static func replacingManagedBlock(
        in text: String,
        overrides: [String: String],
        orderedNames: [String]
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

        guard !overrides.isEmpty else { return lines.joined(separator: "\n") }
        if lines.last?.isEmpty == false { lines.append("") }
        lines.append(beginMarker)
        lines.append("# This block is maintained by Niftty Settings.")

        let known = orderedNames.filter { overrides[$0] != nil }
        let extras = overrides.keys.filter { !orderedNames.contains($0) }.sorted()
        for name in known + extras {
            guard let value = overrides[name] else { continue }
            lines.append("\(name) =")
            for item in value.components(separatedBy: "\n") where !item.isEmpty {
                lines.append("\(name) = \(item)")
            }
        }
        lines.append(endMarker)
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

final class SettingsModel: ObservableObject {
    struct Row: Identifiable {
        let metadata: Ghostty.ConfigEditorSetting
        var value: String
        var hasOverride: Bool

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
    private var overrides: [String: String] = [:]

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    var configPath: String { appDelegate?.ghostty.configFilePath ?? "" }

    var categories: [String] {
        Set(rows.map { Self.category(for: $0.metadata.name) }).sorted()
    }

    var filteredRows: [Row] {
        rows.filter { row in
            guard Self.category(for: row.metadata.name) == selectedCategory else { return false }
            guard !search.isEmpty else { return true }
            return row.metadata.name.localizedCaseInsensitiveContains(search) ||
                row.metadata.description.localizedCaseInsensitiveContains(search) ||
                row.value.localizedCaseInsensitiveContains(search)
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
        rows[index].hasOverride = true
        overrides[name] = value
        hasUnsavedChanges = true
    }

    func resetToDefault(_ name: String) {
        guard let row = rows.first(where: { $0.id == name }) else { return }
        set(row.metadata.defaultValue, for: name)
    }

    func removeOverride(_ name: String) {
        guard let index = rows.firstIndex(where: { $0.id == name }) else { return }
        overrides.removeValue(forKey: name)
        rows[index].hasOverride = false
        rows[index].value = rows[index].metadata.value
        hasUnsavedChanges = true
    }

    func reload() {
        guard let appDelegate else { return }
        do {
            let metadata = try appDelegate.ghostty.config.editorSettings()
            let text = try String(contentsOfFile: appDelegate.ghostty.configFilePath, encoding: .utf8)
            overrides = SettingsFileEditor.overrides(in: text)
            rows = metadata.map { setting in
                Row(
                    metadata: setting,
                    value: overrides[setting.name] ?? setting.value,
                    hasOverride: overrides[setting.name] != nil)
            }
            if !categories.contains(selectedCategory) {
                selectedCategory = categories.first ?? "Appearance"
            }
            hasUnsavedChanges = false
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
            let updated = SettingsFileEditor.replacingManagedBlock(
                in: existing,
                overrides: overrides,
                orderedNames: rows.map(\.id))
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
            appDelegate.ghostty.reloadConfig()
            reload()
        } catch {
            self.error = error.localizedDescription
        }
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
