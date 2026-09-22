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
            let size = ZenStageLayout.stageSize(
                available: geometry.size,
                cellSize: controller.zenCellSize,
                shape: shape)

            stageContent
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.09), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 36, x: 0, y: 14)
                .scaleEffect(isActive || reduceMotion ? 1 : 0.97)
                .opacity(isActive || reduceMotion ? 1 : 0.3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(ZenStageLayout.minimumMargin)
        }
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.985)
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
