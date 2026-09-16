import SwiftUI

/// Titlebar accessory: a Ports button that opens a popover for the focused SSH surface.
struct SSHPortsAccessoryView: View {
    @ObservedObject var viewModel: TerminalWindow.ViewModel
    @State private var showPopover = false
    @State private var tunnelCount = 0
    @State private var hasSession = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if hasSession, let surface = viewModel.focusedSurface {
                Button {
                    showPopover.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cable.connector")
                        if tunnelCount > 0 {
                            Text("\(tunnelCount)")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                        }
                    }
                    .frame(height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .help("SSH port forwards")
                .accessibilityLabel("SSH port forwards")
                .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                    SSHPortsPanel(surfaceView: surface)
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
            tunnelCount = 0
            showPopover = false
            return
        }
        hasSession = true
        Task.detached {
            let count = (try? SSHSessionStore.list(pid: pid).tunnels.count) ?? 0
            await MainActor.run {
                tunnelCount = count
            }
        }
    }
}

/// Host | Remote table plus add/close controls for one SSH surface.
struct SSHPortsPanel: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    @State private var destination = ""
    @State private var tunnels: [SSHSessionStore.Tunnel] = []
    @State private var localPort = ""
    @State private var remotePort = ""
    @State private var errorMessage: String?
    @State private var busy = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SSH Ports")
                    .font(.headline)
                if !destination.isEmpty {
                    Text(destination)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let pid {
                table(pid: pid)
                addRow(pid: pid)
            } else {
                Text("No active SSH session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(width: 420, alignment: .leading)
        .onAppear { refresh() }
        .onReceive(timer) { _ in refresh() }
    }

    private var pid: Int? {
        guard let pid = surfaceView.surfaceModel?.foregroundPID,
              SSHSessionStore.isActive(pid: pid) else { return nil }
        return pid
    }

    @ViewBuilder
    private func table(pid: Int) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Host")
                Text("Remote")
                Color.clear.frame(width: 18)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            if tunnels.isEmpty {
                GridRow {
                    Text("No forwarded ports")
                        .foregroundStyle(.secondary)
                        .gridCellColumns(3)
                }
                .font(.caption)
            } else {
                ForEach(tunnels) { tunnel in
                    GridRow {
                        Text(tunnel.host)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Text(tunnel.remote)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Button {
                            cancel(pid: pid, tunnel: tunnel)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(busy)
                        .accessibilityLabel("Close \(tunnel.host) to \(tunnel.remote)")
                    }
                }
            }
        }
    }

    private func addRow(pid: Int) -> some View {
        HStack(spacing: 8) {
            TextField("Host port", text: $localPort)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 72)
            TextField("Remote port", text: $remotePort)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 72)
            Button("Add") {
                add(pid: pid)
            }
            .disabled(busy || parsedRemote == nil)
        }
        .font(.caption)
    }

    private var parsedLocal: UInt16? {
        parsePort(localPort)
    }

    private var parsedRemote: UInt16? {
        parsePort(remotePort)
    }

    private func parsePort(_ text: String) -> UInt16? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = UInt16(trimmed), value > 0 else { return nil }
        return value
    }

    private func refresh() {
        guard let pid else {
            destination = ""
            tunnels = []
            return
        }
        Task.detached {
            let result = Result { try SSHSessionStore.list(pid: pid) }
            await MainActor.run {
                switch result {
                case .success(let list):
                    destination = list.destination
                    tunnels = list.tunnels
                    if errorMessage != nil, !busy {
                        errorMessage = nil
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func add(pid: Int) {
        guard let remote = parsedRemote else { return }
        let local = parsedLocal
        busy = true
        errorMessage = nil
        Task.detached {
            let result = Result { try SSHSessionStore.add(pid: pid, local: local, remote: remote) }
            await MainActor.run {
                busy = false
                switch result {
                case .success:
                    localPort = ""
                    remotePort = ""
                    refresh()
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cancel(pid: Int, tunnel: SSHSessionStore.Tunnel) {
        busy = true
        errorMessage = nil
        Task.detached {
            let result = Result {
                try SSHSessionStore.cancel(pid: pid, local: tunnel.localPort, remote: tunnel.remotePort)
            }
            await MainActor.run {
                busy = false
                switch result {
                case .success:
                    refresh()
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
