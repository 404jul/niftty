import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HSplitView {
            List(selection: $model.selectedCategory) {
                ForEach(model.sidebarCategories, id: \.self) { category in
                    Label(category, systemImage: icon(for: category))
                        .tag(category)
                }
            }
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 220)

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.selectedCategory)
                            .font(.title2.bold())
                        Text("\(model.filteredRows.count) settings")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Config File") { model.openConfigFile() }
                    Button("Apply") { model.save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.hasUnsavedChanges)
                }
                .padding()

                Divider()

                if model.selectedCategory == "Shaders" {
                    ShadersPage(model: model)
                } else {
                    if let error = model.error {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(error)
                                .textSelection(.enabled)
                            Spacer()
                        }
                        .padding(10)
                        .background(.yellow.opacity(0.12))
                    }

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.filteredRows) { row in
                                SettingRow(model: model, row: row)
                                Divider()
                            }
                        }
                    }
                }


                Divider()
                Text(model.configPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 590)
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search settings")
        .frame(minWidth: 800, minHeight: 560)
    }

    private func icon(for category: String) -> String {
        switch category {
        case "Appearance": "paintbrush"
        case "Clipboard": "clipboard"
        case "Font": "textformat"
        case "Input": "keyboard"
        case "Linux": "desktopcomputer"
        case "macOS": "apple.logo"
        case "Shell": "terminal"
        case "Shaders": "wand.and.stars"
        case "SSH": "network"
        case "Updates": "arrow.triangle.2.circlepath"
        case "Window": "macwindow"
        default: "slider.horizontal.3"
        }
    }
}

private struct SettingRow: View {
    @ObservedObject var model: SettingsModel
    let row: SettingsModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.metadata.name)
                    .font(.headline.monospaced())
                if model.isModified(row.id) {
                    Text("Unsaved")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                Spacer()
                Button("Restore Default") {
                    customFieldFocused = false
                    customPending = false
                    model.restoreDefault(row.id)
                }
                .buttonStyle(.link)
                .disabled(row.value == row.metadata.defaultValue)
            }

            if !row.summary.isEmpty {
                Text(row.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            editor

            Text("Default: \(row.defaultDisplayValue)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .onChange(of: row.value) { newValue in
            // The model can change this value from anywhere (save + reload,
            // restore, etc.). If it lands on a known option, leave custom mode.
            // While our own text field has focus, value changes are the
            // user's in-progress typing, so leave custom mode alone.
            guard !customFieldFocused else { return }
            if newValue.isEmpty || row.metadata.options.contains(newValue) {
                customPending = false
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var editor: some View {
        switch row.metadata.kind {
        case .boolean, .enum:
            HStack(spacing: 8) {
                Picker("Value", selection: selection) {
                    if row.metadata.value.isEmpty {
                        Text("Default: \(row.defaultDisplayValue)").tag("")
                    }
                    ForEach(row.metadata.options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                    if row.metadata.kind == .enum {
                        Text("Custom…").tag(Self.customTag)
                    }
                }
                .frame(maxWidth: 300, alignment: .leading)

                if isCustom {
                    TextField(row.defaultDisplayValue, text: model.binding(for: row.id))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(maxWidth: 300)
                        .focused($customFieldFocused)
                }
            }

        case .text:
            HStack(alignment: .center, spacing: 8) {
                TextField(row.defaultDisplayValue, text: model.binding(for: row.id), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .font(.body.monospaced())
                if row.id == "theme" {
                    Button("Browse Themes") {
                        model.openThemeList()
                    }
                }
            }
        }
    }

    /// True when the current value isn't one of the known options (or the
    /// user just chose "Custom…" for an otherwise-valid value). Only enum
    /// rows can be custom; booleans are always one of their two options.
    private static let customTag = "\0niftty-custom"
    @State private var customPending = false
    @FocusState private var customFieldFocused: Bool

    private var isCustom: Bool {
        row.metadata.kind == .enum
            && (customPending
                || (!row.value.isEmpty && !row.metadata.options.contains(row.value)))
    }

    private var selection: Binding<String> {
        Binding(
            get: { isCustom ? Self.customTag : row.value },
            set: { newValue in
                if newValue == Self.customTag {
                    // Keep the current value for the text field.
                    customPending = true
                } else {
                    customPending = false
                    model.binding(for: row.id).wrappedValue = newValue
                }
            }
        )
    }
}
