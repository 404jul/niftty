import AppKit
import SwiftUI

/// Zen mode presentation for a single terminal window.
///
/// Each window presents zen mode independently: its content view swaps to
/// the zen layout and the window takes over the screen with a non-native
/// fullscreen presentation. Because every zen window covers the screen with
/// identical chrome, switching between workspaces (via ``ZenModeManager``)
/// feels like a single persistent stage.
extension BaseTerminalController {
    /// Presents this window's workspace in zen mode.
    ///
    /// - Returns: True if the window is in zen mode (including if it
    ///   already was).
    @discardableResult
    func zenEnter() -> Bool {
        // Zen mode is a feature of standard terminal windows.
        guard self is TerminalController else { return false }
        guard !isZenMode else { return true }
        guard let window else { return false }

        // Seed the cell size so the stage is sized correctly on the first
        // layout instead of falling back to fraction-only sizing.
        zenCellSize = focusedSurface?.cellSize ?? surfaceTree.first?.cellSize ?? .zero

        // Zen mode owns the window's fullscreen presentation. If the window
        // is already fullscreen, exit that first so we can cleanly restore
        // it later.
        if let style = fullscreenStyle, style.isFullscreen {
            preZenFullscreenStyle = style
            style.exit()
        }

        // Suppress the overlay scrollbar flash on every pane: reparenting
        // the scroll views during the content swap plus the fullscreen
        // resize makes AppKit flash the scroll indicators otherwise.
        setScrollbarsSuppressed(true)

        // Swap the content to the zen layout before going fullscreen so the
        // window resizes with its final content in place.
        installZenContent()

        guard let style = NonNativeFullscreen(window) else {
            restoreTerminalContent()
            return false
        }
        style.delegate = self
        zenSetFullscreenStyle(style)
        style.enter()

        isZenMode = true
        isZenStageActive = true

        // Restore the scrollbars once the content swap and fullscreen
        // resize have fully settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.isZenMode else { return }
            self.setScrollbarsSuppressed(false)
        }

        // Refocus once the content swap and frame change have settled.
        DispatchQueue.main.async { [weak self] in
            self?.zenFocusSurface()
        }

        return true
    }

    /// Restores the window from zen mode.
    func zenExit() {
        guard isZenMode else { return }
        isZenStageActive = false

        // Same suppression as entry: the swap back plus the window resize
        // would flash the scroll indicators on every pane.
        setScrollbarsSuppressed(true)

        // Swap back to the regular terminal layout before exiting
        // fullscreen so the window restores with its real content.
        restoreTerminalContent()

        if let style = fullscreenStyle, style.isFullscreen {
            style.exit()
        }

        // Restore whatever fullscreen style was installed before zen mode.
        zenSetFullscreenStyle(preZenFullscreenStyle)
        preZenFullscreenStyle = nil

        isZenMode = false

        // Restore the scrollbars after the exit transition settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.setScrollbarsSuppressed(false)
        }

        // Refocus once the content swap has settled.
        DispatchQueue.main.async { [weak self] in
            self?.zenFocusSurface()
        }
    }

    /// Updates whether this window is the currently active stage.
    func zenSetStageActive(_ active: Bool) {
        isZenStageActive = active
    }

    /// Moves terminal focus back to the focused (or first) surface. Used
    /// after content swaps which can disturb first responder state.
    func zenFocusSurface() {
        guard let surface = focusedSurface ?? surfaceTree.first else { return }
        moveFocus(to: surface)
    }

    // MARK: Content

    /// Suppresses the overlay scrollbar on every surface in the tree.
    ///
    /// The window's scroll views are reparented by the content swap and
    /// resized by the fullscreen transition, and AppKit flashes the scroll
    /// indicators on each pane when that happens. Hiding the scrollers for
    /// the duration of the transition keeps entry and exit clean.
    ///
    /// TODO(zen): revisit scroll handling later in zen. Suppressing the
    /// scrollbar is a stopgap: ideally the scrollbar stays usable during
    /// the transition (or zen grows its own scroll affordance), and we
    /// avoid the indicator flash without hiding scrollbars entirely.
    private func setScrollbarsSuppressed(_ suppressed: Bool) {
        for view in surfaceTree {
            SurfaceScrollView.wrapping(view)?.isScrollbarSuppressed = suppressed
        }
    }

    /// Swaps the window content to the zen layout. The swap happens within
    /// the existing hosting view so surface views are reparented by SwiftUI
    /// in a single update.
    private func installZenContent() {
        guard let container = window?.contentView as? TerminalViewContainer else { return }
        container.setRootView(AnyView(
            ZenRootView(ghostty: ghostty, controller: self)))
    }

    /// Swaps the window content back to the regular terminal layout.
    private func restoreTerminalContent() {
        guard let container = window?.contentView as? TerminalViewContainer else { return }
        container.setRootView(AnyView(
            TerminalView(ghostty: ghostty, viewModel: self, delegate: self)))
    }
}
