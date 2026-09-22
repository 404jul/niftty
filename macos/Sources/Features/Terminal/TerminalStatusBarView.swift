import SwiftUI

/// A status bar shown at the bottom of a terminal window, displaying
/// information about the currently focused surface.
struct TerminalStatusBarView: View {
    /// The surface to display information for. Nil before any surface
    /// has been focused; the bar renders empty in that case.
    let surface: Ghostty.SurfaceView?

    var body: some View {
        HStack(spacing: 12) {
            if let surface {
                TerminalStatusBarContent(surface: surface)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 22)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }
}

private struct TerminalStatusBarContent: View {
    @ObservedObject var surface: Ghostty.SurfaceView

    /// The SSH-remote working directory when reported, otherwise the
    /// local pwd, with the home directory abbreviated as "~".
    private var displayPath: String? {
        let path = surface.remotePwd?.path ?? surface.pwd
        guard let path, !path.isEmpty else { return nil }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    var body: some View {
        Group {
            HStack(spacing: 4) {
                Image(systemName: surface.remotePwd != nil ? "network" : "folder")
                Text(displayPath ?? "—")
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            if surface.bell {
                Image(systemName: "bell.fill")
                    .fixedSize()
            }

            if !surface.title.isEmpty {
                Text(surface.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let size = surface.surfaceSize {
                Text("\(size.columns)×\(size.rows)")
                    .fixedSize()
            }
        }
    }
}
