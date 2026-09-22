import AppKit
import SwiftUI

/// A snapshot of a terminal workspace (window) as shown in the zen shelf.
struct ZenWorkspace: Identifiable, Equatable {
    /// Stable identity of the workspace, derived from its controller.
    let id: ObjectIdentifier

    /// The window title.
    let title: String

    /// The simplified split shape, or nil for an empty tree.
    let shape: ZenTreeShape?

    /// True if the workspace is currently on the stage.
    let isActive: Bool
}

/// Coordinates zen mode across all terminal windows.
///
/// Zen mode presents each participating terminal window as a fullscreen
/// stage: the window's workspace is centered in a sized frame and all other
/// terminal windows are listed in a Stage Manager-like shelf. Switching
/// workspaces brings the other window forward within the same presentation
/// so the experience feels like a single persistent stage.
///
/// Every zen window covers the full screen with identical chrome, so the
/// user always perceives one stage no matter which window owns it.
@MainActor
final class ZenModeManager: ObservableObject {
    static let shared = ZenModeManager()

    /// The workspaces shown in the shelf, in stable order.
    @Published private(set) var workspaces: [ZenWorkspace] = []

    /// The identity of the controller currently on the stage.
    @Published private(set) var activeID: ObjectIdentifier?

    /// The zen controllers in the order they entered zen mode. Order is
    /// kept stable so shelf targets don't shuffle while working.
    private var controllers: [Weak<BaseTerminalController>] = []

    private init() {}

    /// The controller currently on the stage, if any.
    var activeController: BaseTerminalController? {
        controllers.first(where: { $0.value?.idObject == activeID })?.value
    }

    /// Toggles zen mode for the given controller. This is the entry point
    /// for the menu item and keyboard shortcuts.
    func toggle(_ controller: BaseTerminalController) {
        if controller.isZenMode {
            if controller.idObject == activeID {
                exitAll()
            } else {
                activate(controller)
            }
        } else {
            enter(controller)
            activate(controller)
        }
    }

    /// Presents the given controller's workspace on the zen stage.
    func enter(_ controller: BaseTerminalController) {
        guard controller.zenEnter() else { return }

        if !controllers.contains(where: { $0.value === controller }) {
            controllers.append(Weak(controller))
        }

        refresh()
    }

    /// Brings the given workspace to the stage, entering zen mode on it
    /// first if necessary. This is triggered from the shelf.
    func activate(_ controller: BaseTerminalController) {
        guard controller.isZenMode || controller.zenEnter() else { return }

        if !controllers.contains(where: { $0.value === controller }) {
            controllers.append(Weak(controller))
        }

        let wasActive = activeID == controller.idObject
        activeID = controller.idObject
        controller.zenSetStageActive(true)

        if !wasActive, let window = controller.window {
            window.makeKeyAndOrderFront(nil)

            // A short fade makes the exchange between workspaces legible
            // without drawing attention to the window mechanics.
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                window.alphaValue = 0.3
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().alphaValue = 1
                }
            }
        }

        controller.zenFocusSurface()
        refresh()
    }

    /// Brings the workspace with the given identity to the stage.
    func activate(_ id: ObjectIdentifier) {
        guard let controller = controllers.compactMap(\.value).first(where: { $0.idObject == id }) else {
            return
        }
        activate(controller)
    }

    /// Exits zen mode everywhere, restoring all windows.
    func exitAll() {
        // Exit inactive windows first so the final makeKeyAndOrderFront of
        // each fullscreen exit lands on the active window, leaving it key.
        let exiting = controllers.compactMap(\.value)
        for controller in exiting where controller.idObject != activeID {
            controller.zenExit()
        }
        if let active = activeController {
            active.zenExit()
        }

        controllers = []
        activeID = nil
        refresh()
    }

    /// Called when a controller's window closes so it leaves the shelf.
    func controllerDidClose(_ controller: BaseTerminalController) {
        guard controllers.contains(where: { $0.value === controller }) else { return }

        controllers.removeAll(where: { $0.value === controller })

        if controller.idObject == activeID {
            // Hand the stage to the next workspace rather than dropping the
            // user out of zen mode entirely.
            activeID = nil
            if let next = controllers.compactMap(\.value).first {
                activate(next)
            } else {
                activeID = nil
            }
        }

        refresh()
    }

    /// Rebuilds the published workspace list.
    func refresh() {
        // Prune deallocated controllers.
        controllers.removeAll(where: { $0.value == nil })

        workspaces = controllers.compactMap { weak in
            guard let controller = weak.value else { return nil }
            return ZenWorkspace(
                id: controller.idObject,
                title: controller.window?.title ?? "Terminal",
                shape: ZenStageLayout.shape(of: controller.surfaceTree),
                isActive: controller.idObject == activeID)
        }
    }
}

extension BaseTerminalController {
    /// Stable identity for zen mode bookkeeping.
    var idObject: ObjectIdentifier {
        ObjectIdentifier(self)
    }
}
