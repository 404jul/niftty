import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HSplitView {
            List(selection: $model.selectedCategory) {
                ForEach(model.categories, id: \.self) { category in
                    Label(category, systemImage: icon(for: category))
                        .tag(category)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 220)

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.selectedCategory == "All" ? "Settings" : model.selectedCategory)
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
        case "All": "gearshape"
        case "Appearance": "paintbrush"
        case "Clipboard": "clipboard"
        case "Font": "textformat"
        case "Input": "keyboard"
        case "Linux": "desktopcomputer"
        case "macOS": "apple.logo"
        case "Shell": "terminal"
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
                if row.hasOverride {
                    Text("Modified")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                Spacer()
                Button("Reset") { model.resetToDefault(row.id) }
                    .buttonStyle(.link)
                if row.hasOverride {
                    Button("Use Config File") { model.removeOverride(row.id) }
                        .buttonStyle(.link)
                }
            }

            if !row.summary.isEmpty {
                Text(row.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            editor

            Text("Default: \(row.metadata.defaultValue.isEmpty ? "unset" : row.metadata.defaultValue)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var editor: some View {
        switch row.metadata.kind {
        case .boolean, .enum:
            Picker("Value", selection: model.binding(for: row.id)) {
                if row.metadata.value.isEmpty {
                    Text("Unset").tag("")
                }
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .frame(maxWidth: 300, alignment: .leading)

        case .text:
            TextField("Value", text: model.binding(for: row.id), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .font(.body.monospaced())
        }
    }

    private var options: [String] {
        row.metadata.options.contains(row.value) || row.value.isEmpty
            ? row.metadata.options
            : [row.value] + row.metadata.options
    }
}
