import Testing
import CoreGraphics
@testable import TesseraCore

private let workspace = CGRect(x: 0, y: 0, width: 1000, height: 800)

@Suite("BSP directional resize")
struct BSPResizeTests {

    @Test("Grow-right widens a left pane by moving the shared divider right")
    func growRightFromFirst() {
        var tree = LayoutTree()
        let right = tree.split(PaneID(0), orientation: .horizontal)! // 0 | 1, ratio 0.5
        tree.resize(PaneID(0), .right, by: 0.1) // ratio → 0.6
        let frames = tree.frames(in: workspace)
        #expect(frames[PaneID(0)]?.width == 600)
        #expect(frames[right]?.width == 400)
    }

    @Test("Grow-left from the right pane grows it leftward")
    func growLeftFromSecond() {
        var tree = LayoutTree()
        let right = tree.split(PaneID(0), orientation: .horizontal)! // ratio 0.5
        tree.resize(right, .left, by: 0.1) // right grows left → ratio 0.4
        let frames = tree.frames(in: workspace)
        #expect(frames[PaneID(0)]?.width == 400)
        #expect(frames[right]?.width == 600)
    }

    @Test("Grow-down widens the top pane's height")
    func growDownFromFirst() {
        var tree = LayoutTree()
        let bottom = tree.split(PaneID(0), orientation: .vertical)! // top/bottom
        tree.resize(PaneID(0), .down, by: 0.25) // ratio → 0.75
        let frames = tree.frames(in: workspace)
        #expect(frames[PaneID(0)]?.height == 600)
        #expect(frames[bottom]?.height == 200)
    }

    @Test("Resizing against the outer edge is a no-op")
    func edgeIsNoop() {
        var tree = LayoutTree()
        _ = tree.split(PaneID(0), orientation: .horizontal)!
        // Pane 0 is the left pane; growing it LEFT has no divider on its left.
        let before = tree.frames(in: workspace)
        tree.resize(PaneID(0), .left, by: 0.1)
        let after = tree.frames(in: workspace)
        #expect(before[PaneID(0)] == after[PaneID(0)])
    }

    @Test("Resize adjusts the nearest ancestor split, not a deeper one")
    func nearestAncestor() {
        var tree = LayoutTree()
        // 0 | 1, then split 1 into top/bottom (1a over 1b).
        let right = tree.split(PaneID(0), orientation: .horizontal)!
        let bottomRight = tree.split(right, orientation: .vertical)!
        // Grow the top-right pane to the right: its nearest horizontal ancestor
        // is the root split, where its subtree is the `second` child → grows left
        // edge... actually .right needs it in `first`; the root has it in second,
        // so grow-right is a no-op for the top-right pane.
        let before = tree.frames(in: workspace)
        tree.resize(right, .right, by: 0.1)
        let after = tree.frames(in: workspace)
        #expect(before[right] == after[right])

        // But growing the LEFT pane right does move the root divider.
        tree.resize(PaneID(0), .right, by: 0.1)
        let frames = tree.frames(in: workspace)
        #expect(frames[PaneID(0)]?.width == 600)
        #expect(frames[right]?.width == 400)
        #expect(frames[bottomRight]?.width == 400)
    }

    @Test("Grow/shrink width works from either side of the split")
    func growShrinkEitherSide() {
        var tree = LayoutTree()
        let right = tree.split(PaneID(0), orientation: .horizontal)! // 0 | 1, ratio 0.5

        // Focused = LEFT pane: widen it.
        tree.resize(PaneID(0), axis: .horizontal, grow: true, by: 0.1) // → 0.6
        #expect(tree.frames(in: workspace)[PaneID(0)]?.width == 600)

        // Focused = RIGHT pane: widen it — must also work (the failing case before).
        tree.resize(right, axis: .horizontal, grow: true, by: 0.2) // second grows → ratio 0.6→0.4
        let frames = tree.frames(in: workspace)
        #expect(abs((frames[right]?.width ?? 0) - 600) < 0.01)
        #expect(abs((frames[PaneID(0)]?.width ?? 0) - 400) < 0.01)
    }

    @Test("Grow/shrink height works from either side")
    func growShrinkHeight() {
        var tree = LayoutTree()
        let bottom = tree.split(PaneID(0), orientation: .vertical)! // top/bottom

        tree.resize(bottom, axis: .vertical, grow: true, by: 0.25) // bottom taller → ratio 0.25
        let frames = tree.frames(in: workspace)
        #expect(frames[bottom]?.height == 600)
        #expect(frames[PaneID(0)]?.height == 200)
    }

    @Test("Ratio stays clamped so a pane never collapses")
    func clamped() {
        var tree = LayoutTree()
        _ = tree.split(PaneID(0), orientation: .horizontal)!
        for _ in 0..<20 { tree.resize(PaneID(0), .right, by: 0.2) } // way past 1.0
        let frames = tree.frames(in: workspace)
        // Clamped to 0.95 → 950, never the full 1000.
        #expect(frames[PaneID(0)]?.width == 950)
    }
}
