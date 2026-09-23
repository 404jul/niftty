import SwiftUI

/// The zen mode shelf: a vertical stack of workspace cards on the leading
/// edge of the screen, similar in spirit to macOS Stage Manager. Clicking a
/// card brings that workspace to the stage. The stack scrolls when there
/// are more workspaces than fit vertically.
struct ZenShelfView: View {
    let workspaces: [ZenWorkspace]
    let appeared: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // The stack must live inside a ScrollView even though it only
            // overflows with many workspaces: a plain stack taller than
            // the screen inflates the hosting view's intrinsic content
            // size, and AppKit then grows the window itself to fit (and
            // never shrinks it back), permanently displacing the stage
            // off-center. NSScrollView keeps the overflowing content out
            // of the window's autolayout.
            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 26) {
                        ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
                            ZenShelfCard(
                                workspace: workspace,
                                appeared: appeared,
                                delay: reduceMotion ? 0 : Double(min(index, 6)) * 0.035)
                        }
                    }
                    .padding(.vertical, 16)
                    // Room around the cards so the hover scale-up and its
                    // shadow are not clipped by the scroll view's bounds.
                    .padding(.horizontal, ZenShelfCard.hoverRoom)
                    // Center the cards vertically when they fit the
                    // screen; scroll when they don't.
                    .frame(minHeight: proxy.size.height)
                }
            }
            .frame(width: ZenShelfCard.cardWidth + 2 * ZenShelfCard.hoverRoom)

            Spacer(minLength: 0)
        }
        // Reduced by hoverRoom so the extra viewport width extends
        // outwards without moving the cards on screen.
        .padding(.leading, 28 - ZenShelfCard.hoverRoom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace shelf")
    }
}

/// A single workspace card in the shelf. The card shows a miniature diagram
/// of the workspace's split layout and its title.
private struct ZenShelfCard: View {
    let workspace: ZenWorkspace
    let appeared: Bool
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hovering = false
    @State private var pressing = false

    static let cardWidth: CGFloat = 148

    /// Horizontal room the shelf's scroll viewport keeps around each card
    /// so the hover scale-up (1.03 → 2.2pt per side) and shadow stay inside
    /// the scroll view's clipping bounds.
    static let hoverRoom: CGFloat = 8

    /// The width to height aspect of the preview area, derived from the
    /// workspace's split shape.
    private var aspect: CGFloat {
        guard let shape = workspace.shape else { return 1.3 }
        return ZenStageLayout.cardAspect(for: shape)
    }

    private var previewHeight: CGFloat {
        Self.cardWidth / aspect
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
                .frame(width: Self.cardWidth - 16, height: previewHeight)
                .padding(.top, 8)

            Text(workspace.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 9)
        }
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.white.opacity(0.02))
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(hovering ? .white.opacity(0.22) : .white.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(hovering ? 0.3 : 0.18), radius: hovering ? 16 : 9, x: 0, y: 4)
        .scaleEffect(pressing ? 0.97 : (hovering ? 1.03 : 1))
        .onHover { hovering = $0 }
        .onTapGesture { press() }
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared || reduceMotion ? 0 : -14)
        .animation(
            reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85).delay(delay),
            value: appeared)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressing)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Switch to workspace \(workspace.title)")
        .accessibilityHint(workspace.shape.map { "Terminal with \($0.paneCount) pane\($0.paneCount == 1 ? "" : "s")" } ?? "")
    }

    /// The miniature split layout diagram.
    @ViewBuilder
    private var preview: some View {
        if let shape = workspace.shape {
            ZenShapeDiagram(shape: shape)
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                }
        } else {
            // Empty trees shouldn't appear in the shelf in practice, but
            // keep a quiet placeholder just in case.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.28))
        }
    }

    /// Briefly presses the card before switching. The switch itself happens
    /// immediately so interaction stays snappy.
    private func press() {
        pressing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            pressing = false
            ZenModeManager.shared.activate(workspace.id)
        }
    }
}

/// Draws a miniature representation of a split tree shape.
struct ZenShapeDiagram: View {
    let shape: ZenTreeShape

    var body: some View {
        diagram(shape)
    }

    /// The recursion is type erased because an opaque return type cannot
    /// be defined in terms of itself.
    private func diagram(_ shape: ZenTreeShape) -> AnyView {
        switch shape {
        case .leaf:
            return AnyView(
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.white.opacity(0.16)))
        case .horizontal(let left, let right):
            return AnyView(
                HStack(spacing: 3) {
                    diagram(left)
                    diagram(right)
                })
        case .vertical(let left, let right):
            return AnyView(
                VStack(spacing: 3) {
                    diagram(left)
                    diagram(right)
                })
        }
    }
}
