import AppKit
import SwiftUI

/// Titlebar accessory: an Upload button that opens a popover for the focused SSH surface.
struct SSHUploadAccessoryView: View {
    @ObservedObject var viewModel: TerminalWindow.ViewModel
    @State private var showPopover = false
    @State private var hasSession = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if hasSession, let surface = viewModel.focusedSurface {
                Button {
                    showPopover.toggle()
                } label: {
                    Image(systemName: "arrow.up.circle")
                        .frame(height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help("Upload files over SSH")
                .accessibilityLabel("Upload files over SSH")
                .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                    SSHUploadPanel(surfaceView: surface)
                }
                .padding(.top, viewModel.accessoryTopPadding)
                .padding(.trailing, 10)
            }
            Spacer()
        }
        .onAppear { refresh() }
        .onReceive(timer) { _ in refresh() }
        .onChange(of: viewModel.focusedSurface?.id) { _ in
            showPopover = false
            refresh()
        }
    }

    private func refresh() {
        guard let surface = viewModel.focusedSurface,
              let pid = surface.surfaceModel?.foregroundPID,
              SSHSessionStore.isActive(pid: pid) else {
            hasSession = false
            showPopover = false
            return
        }
        hasSession = true
    }
}

/// Destination line plus file/folder pickers for one SSH surface. Progress
/// and errors render in the surface's existing SSH upload status overlay.
private struct SSHUploadPanel: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Upload")
                    .font(.headline)
                if let remoteDirectory {
                    Text(remoteDirectory)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Waiting for remote directory…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Choose Files…") { chooseFiles() }
                    .buttonStyle(.borderedProminent)
                Button("Choose Folder…") { chooseFolder() }
                    .buttonStyle(.bordered)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
    }

    /// The remote working directory reported via OSC 7 by the foreground
    /// session. A report from a different session is stale and ignored.
    private var remoteDirectory: String? {
        guard let pid = surfaceView.surfaceModel?.foregroundPID,
              let remote = surfaceView.remotePwd,
              remote.sessionPID == pid else { return nil }
        return remote.path
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Upload Files"
        panel.prompt = "Upload"
        panel.canCreateDirectories = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        startUpload(paths: panel.urls.map(\.path))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Upload Folder"
        panel.prompt = "Upload"
        panel.canCreateDirectories = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startUpload(paths: [url.path])
    }

    private func startUpload(paths: [String]) {
        let started = surfaceView.uploadFilesToSSH(paths: paths)
        if started {
            dismiss()
        } else {
            errorMessage = "No active SSH session or remote directory"
        }
    }
}
