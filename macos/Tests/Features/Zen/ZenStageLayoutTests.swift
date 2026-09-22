import AppKit
import Testing
@testable import Ghostty

struct ZenStageLayoutTests {
    // MARK: Shape Extraction

    @Test func singleViewIsLeaf() {
        let view = MockView()
        let tree = SplitTree<MockView>(view: view)
        #expect(ZenStageLayout.shape(of: tree) == .leaf)
    }

    @Test func emptyTreeHasNoShape() {
        let tree = SplitTree<MockView>()
        #expect(ZenStageLayout.shape(of: tree) == nil)
    }

    @Test func horizontalSplitShape() throws {
        let (tree, _, _) = try Self.makeHorizontalSplit()
        #expect(
            ZenStageLayout.shape(of: tree)
                == .horizontal(.leaf, .leaf))
    }

    @Test func verticalSplitShape() throws {
        let (tree, _, _) = try Self.makeVerticalSplit()
        #expect(
            ZenStageLayout.shape(of: tree)
                == .vertical(.leaf, .leaf))
    }

    // MARK: Ideal Content Size

    @Test func leafIdealColumns() {
        #expect(ZenTreeShape.leaf.idealColumns == ZenStageLayout.leafTargetColumns)
        #expect(ZenTreeShape.leaf.idealRows == ZenStageLayout.leafTargetRows)
    }

    @Test func sideBySidePanesAddColumns() {
        let shape = ZenTreeShape.horizontal(.leaf, .leaf)
        #expect(shape.idealColumns == ZenStageLayout.leafTargetColumns * 2)
        #expect(shape.idealRows == ZenStageLayout.leafTargetRows)
    }

    @Test func stackedPanesAddRows() {
        let shape = ZenTreeShape.vertical(.leaf, .leaf)
        #expect(shape.idealRows == ZenStageLayout.leafTargetRows * 2)
        #expect(shape.idealColumns == ZenStageLayout.leafTargetColumns)
    }

    @Test func nestedSplitShape() {
        // (A | B) stacked over C
        let shape = ZenTreeShape.vertical(
            .horizontal(.leaf, .leaf),
            .leaf)
        #expect(shape.paneCount == 3)
        #expect(shape.idealColumns == ZenStageLayout.leafTargetColumns * 2)
        #expect(shape.idealRows == ZenStageLayout.leafTargetRows * 2)
    }

    // MARK: Stage Sizing

    /// A 14" laptop-sized screen in points.
    private static let laptopAvailable = CGSize(width: 1512, height: 982)

    /// An ultrawide screen in points (3440x1440 physical at ~1.5x scale).
    private static let ultrawideAvailable = CGSize(width: 2293, height: 960)

    /// Default-ish cell size.
    private static let cellSize = CGSize(width: 10, height: 21)

    @Test func laptopStageIsLargeButNotFull() {
        let size = ZenStageLayout.stageSize(
            available: Self.laptopAvailable,
            cellSize: Self.cellSize,
            shape: .leaf)

        // Well under the full screen...
        #expect(size.width < Self.laptopAvailable.width)
        #expect(size.height < Self.laptopAvailable.height)

        // ...but still generous.
        #expect(size.width > Self.laptopAvailable.width * 0.7)
        #expect(size.height > Self.laptopAvailable.height * 0.7)
    }

    @Test func ultrawideStageDoesNotFillWidth() {
        let size = ZenStageLayout.stageSize(
            available: Self.ultrawideAvailable,
            cellSize: Self.cellSize,
            shape: .leaf)

        // The content-driven cap must bind long before the screen width,
        // otherwise a single terminal would be comically wide.
        #expect(size.width < Self.ultrawideAvailable.width * 0.7)

        // Comfortable margins remain on every side.
        #expect(Self.ultrawideAvailable.width - size.width >= ZenStageLayout.minimumMargin * 2)
        #expect(Self.ultrawideAvailable.height - size.height >= ZenStageLayout.minimumMargin * 2)
    }

    @Test func stageNeverExceedsFractionOfScreen() {
        let shapes: [ZenTreeShape] = [
            .leaf,
            .horizontal(.leaf, .leaf),
            .vertical(.leaf, .leaf),
            .vertical(.horizontal(.leaf, .leaf), .leaf),
            .horizontal(
                .vertical(.leaf, .leaf),
                .vertical(.leaf, .leaf)),
        ]

        for available in [Self.laptopAvailable, Self.ultrawideAvailable] {
            for shape in shapes {
                let size = ZenStageLayout.stageSize(
                    available: available,
                    cellSize: Self.cellSize,
                    shape: shape)

                #expect(size.width <= available.width * ZenStageLayout.maxScreenFraction + 0.001)
                #expect(size.height <= available.height * ZenStageLayout.maxScreenFraction + 0.001)
            }
        }
    }

    @Test func splitsAreBiggerThanSinglePaneWhenRoomAllows() {
        // On an ultrawide a single pane's ideal size is below the cap, so
        // there is headroom for a split to grow into.
        let single = ZenStageLayout.stageSize(
            available: Self.ultrawideAvailable,
            cellSize: Self.cellSize,
            shape: .leaf)

        let pair = ZenStageLayout.stageSize(
            available: Self.ultrawideAvailable,
            cellSize: Self.cellSize,
            shape: .horizontal(.leaf, .leaf))

        #expect(pair.width > single.width)
    }

    @Test func hugeSplitsAreStillCappedByScreen() {
        // A deeply nested tree that wants far more cells than any screen
        // has: the stage must still respect the screen bounds.
        var shape = ZenTreeShape.leaf
        for _ in 0..<5 {
            shape = .horizontal(shape, shape)
        }

        let size = ZenStageLayout.stageSize(
            available: Self.ultrawideAvailable,
            cellSize: Self.cellSize,
            shape: shape)

        #expect(size.width <= Self.ultrawideAvailable.width)
        #expect(size.height <= Self.ultrawideAvailable.height)
    }

    @Test func unknownCellSizeFallsBackToFractions() {
        let size = ZenStageLayout.stageSize(
            available: Self.laptopAvailable,
            cellSize: .zero,
            shape: .leaf)

        #expect(size.width == Self.laptopAvailable.width * ZenStageLayout.maxScreenFraction)
        #expect(size.height == Self.laptopAvailable.height * ZenStageLayout.maxScreenFraction)
    }

    @Test func largeCellSizeStillFitsScreen() throws {
        // User zoomed their font way in: the ideal cell count may exceed
        // the screen, so the fraction cap must win.
        let size = ZenStageLayout.stageSize(
            available: Self.laptopAvailable,
            cellSize: CGSize(width: 40, height: 80),
            shape: .leaf)

        #expect(size.width <= Self.laptopAvailable.width * ZenStageLayout.maxScreenFraction + 0.001)
        #expect(size.height <= Self.laptopAvailable.height * ZenStageLayout.maxScreenFraction + 0.001)
    }

    // MARK: Card Aspect

    @Test func cardAspectIsClamped() {
        // A single pane is landscape-ish.
        #expect(ZenStageLayout.cardAspect(for: .leaf) > 1)

        // Extremely tall or wide trees are clamped into a presentable
        // range.
        let tall = ZenTreeShape.vertical(.leaf, .leaf)
        let wide = ZenTreeShape.horizontal(.leaf, .leaf)
        #expect(ZenStageLayout.cardAspect(for: tall) >= 0.7)
        #expect(ZenStageLayout.cardAspect(for: wide) <= 1.9)
    }

    // MARK: Helpers

    private static func makeHorizontalSplit() throws -> (SplitTree<MockView>, MockView, MockView) {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .right)
        return (tree, view1, view2)
    }

    private static func makeVerticalSplit() throws -> (SplitTree<MockView>, MockView, MockView) {
        let view1 = MockView()
        let view2 = MockView()
        var tree = SplitTree<MockView>(view: view1)
        tree = try tree.inserting(view: view2, at: view1, direction: .down)
        return (tree, view1, view2)
    }
}
