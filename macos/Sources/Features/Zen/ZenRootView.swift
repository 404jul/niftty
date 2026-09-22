import SwiftUI

/// The root view for zen mode: a fullscreen backdrop with the terminal
/// workspace centered on a stage and other workspaces in a shelf on the
/// leading edge.
struct ZenRootView: View {
    @ObservedObject var ghostty: Ghostty.App
    @ObservedObject var controller: BaseTerminalController
    @ObservedObject var zen = ZenModeManager.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Set once the view appeared so entry animations can run.
    @State private var appeared = false

    private var isActive: Bool {
        controller.isZenStageActive && zen.activeID == controller.idObject
    }

    /// The terminal background color the stage and backdrop are derived
    /// from, keeping zen mode feeling native to the user's theme.
    private var backgroundColor: Color {
        controller.focusedSurface?.derivedConfig.backgroundColor
            ?? Color(NSColor.windowBackgroundColor)
    }

    var body: some View {
        ZStack {
            backdrop

            if !zen.workspaces.isEmpty {
                ZenShelfView(
                    workspaces: zen.workspaces.filter { !$0.isActive },
                    appeared: appeared)
                    .transition(.opacity)
            }

            stage
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: appeared)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: zen.activeID)
        .onAppear {
            // Let the fullscreen presentation settle for a tick before
            // animating the stage and shelf in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                appeared = true
            }
        }
    }

    // MARK: Backdrop

    private var backdrop: some View {
        backgroundColor
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.45), location: 0),
                        .init(color: .black.opacity(0.62), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom))
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    // MARK: Stage

    @ViewBuilder
    private var stage: some View {
        GeometryReader { geometry in
            let shape = ZenStageLayout.shape(of: controller.surfaceTree) ?? .leaf
            // Size against the final fullscreen frame rather than the live
            // window size: zen swaps the content while the window is still
            // at its old frame and only resizes the window afterwards, so
            // live geometry would lay the terminal out twice (once small,
            // once full) and the stage would visibly jitter through both.
            // The stage is hidden until the presentation settles, so the
            // single reflow at the final size happens while invisible.
            // NonNativeFullscreen frames zen windows on screen.frame (it
            // hides the menu and dock), and the stage's own margin and
            // fraction limits keep it inside the window regardless.
            let size = ZenStageLayout.stageSize(
                available: controller.window?.screen?.frame.size ?? geometry.size,
                cellSize: controller.zenCellSize,
                shape: shape)

            stageContent
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.09), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 36, x: 0, y: 14)
                // Deliberately no scaleEffect anywhere on the stage: the
                // hosted terminal views re-layout (not GPU-transform) under
                // SwiftUI scale effects, and each step is a cell-snapped
                // resize that makes the terminal shake. Fade only.
                .opacity(isActive || reduceMotion ? 1 : 0.3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(ZenStageLayout.minimumMargin)
        }
        .opacity(appeared ? 1 : 0)
    }

    /// The terminal split tree rendered within the stage.
    private var stageContent: some View {
        TerminalSplitTreeView(
            tree: controller.surfaceTree,
            action: { controller.performSplitAction($0) })
            .environmentObject(ghostty)
            .padding(ZenStageLayout.stagePadding)
            .background(backgroundColor)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Zen terminal stage")
    }
}
