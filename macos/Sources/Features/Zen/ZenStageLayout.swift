import CoreGraphics
import Foundation

/// A simplified representation of a split tree shape used by zen mode to
/// size the stage and draw miniature layout diagrams.
///
/// This is intentionally decoupled from `SplitTree` so that sizing logic is
/// pure and unit testable without any views.
enum ZenTreeShape: Equatable {
    /// A single terminal pane.
    case leaf

    /// Panes laid out left and right.
    indirect case horizontal(ZenTreeShape, ZenTreeShape)

    /// Panes laid out top and bottom.
    indirect case vertical(ZenTreeShape, ZenTreeShape)

    /// The number of terminal panes (leaves) in this shape.
    var paneCount: Int {
        switch self {
        case .leaf:
            return 1
        case .horizontal(let left, let right), .vertical(let left, let right):
            return left.paneCount + right.paneCount
        }
    }

    /// The number of terminal columns zen mode should ideally allocate.
    ///
    /// Side-by-side panes add their widths because each pane needs enough
    /// columns to be usable. Stacked panes only need the wider of the two.
    var idealColumns: Int {
        switch self {
        case .leaf:
            return ZenStageLayout.leafTargetColumns
        case .horizontal(let left, let right):
            return left.idealColumns + right.idealColumns
        case .vertical(let left, let right):
            return max(left.idealColumns, right.idealColumns)
        }
    }

    /// The number of terminal rows zen mode should ideally allocate.
    ///
    /// This is the row-based mirror of ``idealColumns``.
    var idealRows: Int {
        switch self {
        case .leaf:
            return ZenStageLayout.leafTargetRows
        case .vertical(let left, let right):
            return left.idealRows + right.idealRows
        case .horizontal(let left, let right):
            return max(left.idealRows, right.idealRows)
        }
    }
}

/// Sizing logic for the zen mode stage.
///
/// The stage is the centered area that hosts the focused terminal workspace.
/// It must feel generous on a laptop but must not become comically large on
/// an ultrawide or high resolution display. To do this we combine two limits:
///
/// 1. A fraction of the usable screen area, so the stage always leaves
///    comfortable margins.
/// 2. A content-driven ideal size measured in terminal cells, so the stage
///    grows with splits but stops growing once each pane has plenty of
///    room, regardless of how large the display is.
enum ZenStageLayout {
    /// The target number of columns for a single pane on the stage.
    static let leafTargetColumns = 130

    /// The target number of rows for a single pane on the stage.
    static let leafTargetRows = 38

    /// The maximum fraction of the screen (per axis) the stage may occupy.
    static let maxScreenFraction: CGFloat = 0.86

    /// The minimum margin kept clear on every side of the screen.
    static let minimumMargin: CGFloat = 48

    /// Padding between the stage border and the terminal content within it.
    static let stagePadding: CGFloat = 12

    /// Converts a split tree node into its simplified zen shape.
    static func shape<V>(of node: SplitTree<V>.Node) -> ZenTreeShape {
        switch node {
        case .leaf:
            return .leaf
        case .split(let split):
            let left = shape(of: split.left)
            let right = shape(of: split.right)
            return switch split.direction {
            case .horizontal: .horizontal(left, right)
            case .vertical: .vertical(left, right)
            }
        }
    }

    /// Converts a split tree into its simplified zen shape. Returns nil for
    /// an empty tree.
    static func shape<V>(of tree: SplitTree<V>) -> ZenTreeShape? {
        guard let root = tree.root else { return nil }
        return shape(of: root)
    }

    /// Calculates the stage size for the given screen space, cell metrics,
    /// and split shape.
    ///
    /// - Parameters:
    ///   - available: The usable screen area in points (e.g. the window or
    ///     screen frame zen mode is presented in).
    ///   - cellSize: The size in points of a single terminal cell. May be
    ///     zero before the first layout, in which case fraction-based
    ///     sizing is used.
    ///   - shape: The simplified split shape of the workspace.
    /// - Returns: The stage size in points.
    static func stageSize(
        available: CGSize,
        cellSize: CGSize,
        shape: ZenTreeShape
    ) -> CGSize {
        // Fraction-driven maximums, always keeping at least the minimum
        // margin clear on every side.
        let maxWidth = min(
            available.width * maxScreenFraction,
            max(0, available.width - minimumMargin * 2))
        let maxHeight = min(
            available.height * maxScreenFraction,
            max(0, available.height - minimumMargin * 2))

        // Before the terminal reports its cell size we fall back to
        // fraction-only sizing so the stage still appears.
        guard cellSize.width > 0, cellSize.height > 0 else {
            return CGSize(width: maxWidth, height: maxHeight)
        }

        // The content-driven ideal size: enough cells for every pane to be
        // comfortable, plus padding around the content.
        let idealWidth = CGFloat(shape.idealColumns) * cellSize.width + stagePadding * 2
        let idealHeight = CGFloat(shape.idealRows) * cellSize.height + stagePadding * 2

        return CGSize(
            width: min(idealWidth, maxWidth),
            height: min(idealHeight, maxHeight))
    }

    /// The width to height aspect ratio to use for a shelf card previewing
    /// this shape. Clamped so cards stay presentable.
    static func cardAspect(for shape: ZenTreeShape) -> CGFloat {
        let columns = CGFloat(shape.idealColumns)
        let rows = CGFloat(shape.idealRows)
        guard rows > 0 else { return 1 }
        return min(1.9, max(0.7, columns / rows))
    }
}
