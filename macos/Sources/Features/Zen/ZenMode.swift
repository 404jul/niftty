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
/// Zen mode is global: while active, exactly one terminal window — the
/// stage — is visible. It presents the active workspace centered on the
/// screen with the app's other terminal windows hidden and listed in a
/// Stage Manager-like shelf. Hidden windows keep their workspaces (splits
/// and all) running; switching workspaces unhides the next window within
/// the same presentation. Because the other windows are ordered out, the
/// Dock, app switcher, and Mission Control expose a single zen window.
/// Exiting zen mode restores every window.
@MainActor
final class ZenModeManager: ObservableObject {
    static let shared = ZenModeManager()

    /// The workspaces shown in the shelf, in stable order.
    @Published private(set) var workspaces: [ZenWorkspace] = []

    /// The identity of the controller currently on the stage.
    @Published private(set) var activeID: ObjectIdentifier?

    /// The zen workspaces in the order they joined zen mode. Order is
    /// kept stable so shelf targets don't shuffle while working.
    private var controllers: [Weak<BaseTerminalController>] = []

    /// Workspaces whose windows were created by new-tab actions while zen
    /// mode was active. Their windows never belonged to a tab group, so
    /// exiting zen mode folds them back into the stage's tab group (see
    /// ``exitAll()``) instead of leaving them as separate windows.
    private var tabsToRestore: Set<ObjectIdentifier> = []

    /// Last-on-stage content snapshot per workspace, shown on shelf cards.
    @Published private(set) var snapshots: [ObjectIdentifier: NSImage] = [:]

    /// Target width of captured shelf snapshots, in points.
    private static let snapshotWidth: CGFloat = 300

    private init() {}

    /// True while zen mode is presenting across the app.
    var isActive: Bool { activeID != nil }

    /// The controller currently on the stage, if any.
    var activeController: BaseTerminalController? {
        controllers.first(where: { $0.value?.idObject == activeID })?.value
    }

    /// Toggles zen mode for the given controller. This is the entry point
    /// for the menu item and keyboard shortcuts.
    func toggle(_ controller: BaseTerminalController) {
        if isActive {
            if controller.idObject == activeID {
                exitAll()
            } else {
                activate(controller)
            }
        } else {
            begin(controller)
        }
    }

    /// Starts zen mode with the given controller's window as the stage.
    /// Every other terminal window joins the presentation hidden so zen
    /// mode reads as a single global window.
    private func begin(_ controller: BaseTerminalController) {
        guard controller.zenEnter() else { return }

        tabsToRestore = []
        controllers = [Weak(controller)]
        activeID = controller.idObject
        controller.zenSetStageActive(true)

        let others = TerminalController.all.filter { $0 !== controller }
        for other in others {
            other.zenSetStageActive(false)
            controllers.append(Weak(other))
        }

        // Hide the other windows once the stage has taken the screen (its
        // fullscreen frame lands on the next tick) so nothing flashes
        // through while the presentation settles.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive else { return }
            for other in others {
                self.captureSnapshot(of: other)
                other.window?.orderOut(nil)
            }
        }

        controller.zenFocusSurface()
        refresh()
    }


    /// Brings the given workspace to the stage, entering zen mode on it
    /// first if necessary. This is triggered from the shelf.
    ///
    /// - Parameter animated: Pass false when the window is freshly entering
    ///   zen mode, to skip the fade reserved for exchanging workspaces.
    /// - Parameter asNewTab: Pass true when the workspace is a window
    ///   created by a new-tab action while zen mode is active. Exiting zen
    ///   mode restores it as a native tab of the stage's tab group instead
    ///   of a separate window (see ``exitAll()``).
    func activate(
        _ controller: BaseTerminalController,
        animated: Bool = true,
        asNewTab: Bool = false
    ) {
        guard isActive else { return }
        guard controller.isZenMode || controller.zenEnter() else { return }

        if !controllers.contains(where: { $0.value === controller }) {
            controllers.append(Weak(controller))
        }
        if asNewTab {
            tabsToRestore.insert(controller.idObject)
        }

        let wasActive = activeID == controller.idObject
        if !wasActive {
            activeController?.zenSetStageActive(false)
            activeID = controller.idObject
            controller.zenSetStageActive(true)
        }

        // Only the stage may stay visible: every other zen window is
        // ordered out so Mission Control and the app switcher expose a
        // single window. The previous stage may only disappear once this
        // window fully covers the screen — while it is translucent or
        // still taking its fullscreen frame, the window beneath it must
        // stay visible or the desktop shows through. The active check is
        // re-evaluated at execution so a rapid switch to yet another
        // workspace supersedes a pending hide.
        let hideOthers: () -> Void = { [weak self, weak controller] in
            guard let self, self.isActive, self.activeID == controller?.idObject else { return }
            for other in self.controllers.compactMap(\.value)
            where other.idObject != self.activeID {
                self.captureSnapshot(of: other)
                other.window?.orderOut(nil)
            }
        }

        if let window = controller.window {
            window.makeKeyAndOrderFront(nil)

            // The reveal is strictly monotonic toward opaque: the alpha is
            // never reset downward here. Resetting it (and animating back
            // up) compounds when workspaces are switched faster than the
            // animation completes, and can leave the stage transparent.
            // The exchange fade the user sees comes from the stage
            // content's own opacity animation; the window itself only
            // ever becomes more opaque.
            //
            // The previous stage stays beneath until this window fully
            // covers the screen: the hide runs at fade completion, or for
            // an already-opaque window on the tick after its fullscreen
            // frame has landed.
            if !wasActive, animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               window.alphaValue < 1 {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().alphaValue = 1
                }, completionHandler: {
                    hideOthers()
                })
            } else {
                window.alphaValue = 1
                // Keep the previous stage on screen briefly after this
                // window is fronted. A freshly ordered-in window needs a
                // compositor cycle before its content actually renders;
                // hiding the window beneath on the very next tick can
                // leave nothing drawn for a frame or two, which shows up
                // as the desktop flashing through during rapid workspace
                // switching. The recheck inside hideOthers supersedes
                // this if the user switches again within the grace
                // period.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    hideOthers()
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

    /// Activates the workspace at the given shelf index. Returns false if
    /// the index is out of range. This is the zen equivalent of
    /// `goto_tab:N` while in zen mode.
    @discardableResult
    func activateWorkspace(at index: Int) -> Bool {
        let list = controllers.compactMap(\.value)
        guard list.indices.contains(index) else { return false }
        activate(list[index])
        return true
    }

    /// Activates the workspace offset positions from the currently active
    /// one, wrapping around the shelf order. Returns false if there are
    /// fewer than two workspaces. This is the zen equivalent of
    /// `goto_tab:previous` and `goto_tab:next`.
    @discardableResult
    func activateWorkspace(offsetFromActive offset: Int) -> Bool {
        let list = controllers.compactMap(\.value)
        guard list.count > 1 else { return false }
        guard let index = list.firstIndex(where: { $0.idObject == activeID }) else { return false }
        let target = (index + offset + list.count) % list.count
        activate(list[target])
        return true
    }

    /// Moves the given workspace within the shelf order, clamped to the
    /// ends. This is the zen equivalent of `move_tab`.
    func move(_ controller: BaseTerminalController, by offset: Int) {
        guard offset != 0 else { return }
        guard let index = controllers.firstIndex(where: { $0.value === controller }) else { return }
        let target = min(max(index + offset, 0), controllers.count - 1)
        guard target != index else { return }
        controllers.move(fromOffsets: IndexSet(integer: index), toOffset: target > index ? target + 1 : target)
        refresh()
    }

    /// Exits zen mode everywhere, restoring all windows.
    ///
    /// Workspaces created as tabs while zen was active become native tabs
    /// of the stage's tab group again, in shelf order. Windows that
    /// predated zen mode keep whatever arrangement they had: a stage that
    /// left a tab group rejoins it through its fullscreen exit, and the
    /// hidden windows are re-shown through their group's selected window
    /// so group membership and selection survive.
    func exitAll() {
        guard isActive else { return }

        let stage = activeController
        let exiting = controllers.compactMap(\.value)
        let newTabs = exiting.filter { controller in
            controller !== stage && tabsToRestore.remove(controller.idObject) != nil
        }
        tabsToRestore.removeAll()
        controllers = []
        activeID = nil
        snapshots = [:]

        // Tear down every workspace's zen presentation but the stage's.
        // Windows that never took the stage are untouched (zenExit is a
        // no-op for them); fullscreen workspaces get their titled window
        // back at the frame they had before joining zen.
        for controller in exiting where controller !== stage {
            controller.zenExit()
        }

        // The stage must exit fullscreen before re-tabbing: its exit is
        // what restores the titled style (and rejoins its original tab
        // group) that native tabs require.
        stage?.zenExit()

        // Turn the zen shelf back into a real tab bar. All of this runs in
        // one event-loop tick with the exits above, so the workspaces never
        // visibly pass through their restored standalone frames on the way
        // into the group.
        if let stageWindow = stage?.window {
            for controller in newTabs {
                guard let window = controller.window else { continue }
                let target = stageWindow.tabGroup?.windows.last ?? stageWindow
                target.addTabbedWindowSafely(window, ordered: .above)
            }
            stageWindow.tabGroup?.selectedWindow = stageWindow
        }

        // Re-show the windows zen mode ordered out. Tab groups are revealed
        // once through their selected window because ordering in one member
        // of a group brings the whole group along; this keeps the group's
        // selection state instead of cycling through every tab.
        var revealedGroups = Set<ObjectIdentifier>()
        for controller in exiting where controller !== stage {
            guard !newTabs.contains(where: { $0 === controller }) else { continue }
            guard let window = controller.window else { continue }
            if let group = window.tabGroup {
                guard revealedGroups.insert(ObjectIdentifier(group)).inserted else { continue }
                (group.selectedWindow ?? window).makeKeyAndOrderFront(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
            }
        }

        // The stage was on screen when zen mode ended; it ends key.
        stage?.window?.makeKeyAndOrderFront(nil)

        refresh()
    }

    /// Called when a controller's window closes so it leaves the shelf.
    func controllerDidClose(_ controller: BaseTerminalController) {
        guard controllers.contains(where: { $0.value === controller }) else { return }

        controllers.removeAll(where: { $0.value === controller })
        tabsToRestore.remove(controller.idObject)
        snapshots.removeValue(forKey: controller.idObject)

        // The closing window must not run the normal fullscreen exit: it
        // would restore the window's pre-zen frame and title bar mid-close
        // (a small window flashing behind the close animation) and re-add
        // the window to any tab group it left. Release only the system
        // chrome references its fullscreen holds; the menu bar and dock
        // return when the last zen window goes away.
        if let nonNative = controller.fullscreenStyle as? NonNativeFullscreen {
            nonNative.releaseSystemChrome()
        }

        if controller.idObject == activeID {
            // Hand the stage to the next workspace rather than dropping the
            // user out of zen mode entirely. activate replaces the active
            // workspace, so keep the closing one current until then.
            if let next = controllers.compactMap(\.value).first {
                // The closing stage disappears immediately, so the next
                // workspace must not fade in over the desktop.
                activate(next, animated: false)
            } else {
                // The last workspace closed; zen mode is over.
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

    /// Captures the given controller's window content for its shelf card.
    /// Called immediately before the window is ordered out, while it is
    /// still on screen and composited; hidden zen workspaces cannot have
    /// live thumbnails, so this snapshot is what the card shows until the
    /// workspace next leaves the stage.
    private func captureSnapshot(of controller: BaseTerminalController) {
        guard let window = controller.window,
              window.occlusionState.contains(.visible),
              window.alphaValue >= 0.99 else { return }

        // Deprecated on macOS 14 in favor of ScreenCaptureKit but still
        // functional and the only synchronous API; capturing our own
        // windows requires no screen-recording permission.
        guard let cgImage = CGWindowListCreateImage(
            .null, [.optionIncludingWindow], CGWindowID(window.windowNumber),
            [.bestResolution, .boundsIgnoreFraming]) else { return }

        let scale = Self.snapshotWidth / CGFloat(cgImage.width)
        let size = NSSize(width: Self.snapshotWidth,
                          height: CGFloat(cgImage.height) * scale)

        let image = NSImage(size: size)
        image.lockFocus()
        NSImage(cgImage: cgImage, size: size)
            .draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        snapshots[controller.idObject] = image
    }
}

extension BaseTerminalController {
    /// Stable identity for zen mode bookkeeping.
    var idObject: ObjectIdentifier {
        ObjectIdentifier(self)
    }
}
