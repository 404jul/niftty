import SwiftUI

/// The Updates page in the graphical settings editor. Offers a manual
/// check for updates with live status, above the `auto-update` config
/// rows rendered by the shared row editor.
struct UpdatesPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var update: UpdateViewModel

    init(model: SettingsModel) {
        self.model = model
        self.update = model.updateViewModel
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                checkSection
                Divider()
                ForEach(model.filteredRows) { row in
                    SettingRow(model: model, row: row)
                    Divider()
                }
            }
        }
    }

    private var checkSection: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Check for Updates")
                    .font(.headline.monospaced())
                Text(status)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer()

            if let cancel = cancelAction {
                Button("Cancel") { cancel() }
            }
            if case .updateAvailable = update.state {
                Button("Install and Restart") { update.state.confirm() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Check Now") { model.checkForUpdates() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// Status of the update system for display under the section title.
    private var status: String {
        if case .idle = update.state {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            if let version, !version.isEmpty {
                return "Current version \(version). Automatic checks follow the setting below."
            }
            return ""
        }
        return update.text
    }

    private var statusColor: Color {
        if case .error = update.state { return .orange }
        return .secondary
    }

    /// Cancel for the transient progress states, mirroring the command
    /// palette's cancel option. Other cancellable states are dismissals
    /// handled by their own UI.
    private var cancelAction: (() -> Void)? {
        switch update.state {
        case .checking(let checking): checking.cancel
        case .downloading(let downloading): downloading.cancel
        default: nil
        }
    }
}
