import Testing
import CoreGraphics
@testable import TesseraCore

/// The workspace rect used across most tests — a clean 1000×800 so ratios and
/// gaps produce exact, assertion-friendly numbers.
private let workspace = CGRect(x: 0, y: 0, width: 1000, height: 800)

@Suite("BSP layout engine")
struct BSPLayoutTests {

    @Test("A single pane fills the whole workspace")
    func singlePaneFillsWorkspace() {
        let tree = LayoutTree()
        let frames = tree.frames(in: workspace)
        #expect(frames.count == 1)
        #expect(frames[PaneID(0)] == workspace)
    }

    @Test("Horizontal split places children left and right, 50/50")
    func horizontalSplitHalves() {
        var tree = LayoutTree()
        let right = tree.split(PaneID(0), orientation: .horizontal)
        #expect(right == PaneID(1))

        let frames = tree.frames(in: workspace)
        #expect(frames[PaneID(0)] == CGRect(x: 0, y: 0, width: 500, height: 800))
        #expect(frames[PaneID(1)] == CGRect(x: 500, y: 0, width: 500, height: 800))
    }

    @Test("Vertical split places children top and bottom, 50/50")
    func verticalSplitHalves() {
        var tree = LayoutTree()
        _ = tree.split(PaneID(0), orientation: .vertical)
        let frames = tree.frames(in: workspace)
        // In top-left-origin space, `first` is the topmost child.
        #expect(frames[PaneID(0)] == CGRect(x: 0, y: 0, width: 1000, height: 400))
        #expect(frames[PaneID(1)] == CGRect(x: 0, y: 400, width: 1000, height: 400))
    }

    @Test("Non-even ratio divides the extent proportionally")
    func customRatio() {
        var tree = LayoutTree()
        _ = tree.split(PaneID(0), orientation: .horizontal, ratio: 0.7)
        let frames = tree.frames(in: workspace)
        #expect(frames[PaneID(0)]?.width == 700)
        #expect(frames[PaneID(1)]?.width == 300)
        #expect(frames[PaneID(1)]?.minX == 700)
    }

    @Test("Ratio is clamped so a split never yields a zero-extent pane")
    func ratioClamped() {
        var tree = LayoutTree()
        _ = tree.split(PaneID(0), orientation: .horizontal, ratio: 5.0)
        let frames = tree.frames(in: workspace)
        // Clamped to 0.95 → 950 / 50, never 1000 / 0.
        #expect(frames[PaneID(0)]?.width == 950)
        #expect(frames[PaneID(1)]?.width == 50)
    }

    @Test("Nested splits tile the workspace without gaps or overlap")
    func nestedSplits() {
        var tree = LayoutTree()
        // Split into left/right, then split the right pane top/bottom.
        let right = tree.split(PaneID(0), orientation: .horizontal)!
        let bottomRight = tree.split(right, orientation: .vertical)!

        let frames = tree.frames(in: workspace)
        #expect(frames.count == 3)
        #expect(frames[PaneID(0)] == CGRect(x: 0, y: 0, width: 500, height: 800))       // left
        #expect(frames[right] == CGRect(x: 500, y: 0, width: 500, height: 400))          // top-right
        #expect(frames[bottomRight] == CGRect(x: 500, y: 400, width: 500, height: 400))  // bottom-right

        // The three panes exactly cover the workspace area.
        let totalArea = frames.values.reduce(0) { $0 + $1.width * $1.height }
        #expect(totalArea == workspace.width * workspace.height)
    }

    @Test("Inner gap reserves space between siblings and shifts the second")
    func innerGap() {
        var tree = LayoutTree()
        _ = tree.split(PaneID(0), orientation: .horizontal)
        let frames = tree.frames(in: workspace, config: LayoutConfig(innerGap: 20))
        // 1000 - 20 gap = 980 usable → 490 each; second starts at 490 + 20.
        #expect(frames[PaneID(0)] == CGRect(x: 0, y: 0, width: 490, height: 800))
        #expect(frames[PaneID(1)] == CGRect(x: 510, y: 0, width: 490, height: 800))
    }

    @Test("Outer gap insets the whole workspace on all sides")
    func outerGap() {
        let tree = LayoutTree()
        let frames = tree.frames(in: workspace, config: LayoutConfig(outerGap: 10))
        #expect(frames[PaneID(0)] == CGRect(x: 10, y: 10, width: 980, height: 780))
    }

    @Test("Window insets trim each pane cell (titlebar/border knob)")
    func windowInsets() {
        let tree = LayoutTree()
        let insets = EdgeInsets(top: 28, left: 2, bottom: 2, right: 2)
        let frames = tree.frames(in: workspace, config: LayoutConfig(windowInsets: insets))
        #expect(frames[PaneID(0)] == CGRect(x: 2, y: 28, width: 996, height: 770))
    }

    @Test("Removing a pane collapses its sibling into the parent's space")
    func removeCollapsesSibling() {
        var tree = LayoutTree()
        let right = tree.split(PaneID(0), orientation: .horizontal)!
        _ = tree.split(right, orientation: .vertical)! // right → top/bottom

        tree.remove(right) // remove the top-right; bottom-right should fill the right half
        #expect(tree.paneIDs.count == 2)

        let frames = tree.frames(in: workspace)
        #expect(frames[PaneID(0)] == CGRect(x: 0, y: 0, width: 500, height: 800))
        // The surviving sibling now occupies the entire right half.
        let survivor = tree.paneIDs.first { $0 != PaneID(0) }!
        #expect(frames[survivor] == CGRect(x: 500, y: 0, width: 500, height: 800))
    }

    @Test("Removing the last pane is a no-op — a workspace keeps one pane")
    func removeLastPaneIsNoop() {
        var tree = LayoutTree()
        tree.remove(PaneID(0))
        #expect(tree.paneIDs == [PaneID(0)])
    }

    @Test("Splitting a non-existent pane changes nothing")
    func splitUnknownPaneNoop() {
        var tree = LayoutTree()
        let result = tree.split(PaneID(999), orientation: .horizontal)
        #expect(result == nil)
        #expect(tree.paneIDs == [PaneID(0)])
    }

    @Test("Resizing adjusts the nearest ancestor split ratio")
    func resizePane() {
        var tree = LayoutTree()
        let right = tree.split(PaneID(0), orientation: .horizontal)!
        tree.resize(right, toRatio: 0.25) // give `first` (left) 25%
        let frames = tree.frames(in: workspace)
        #expect(frames[PaneID(0)]?.width == 250)
        #expect(frames[right]?.width == 750)
    }

    @Test("Leaf ids preserve left-to-right / top-to-bottom order")
    func leafOrder() {
        var tree = LayoutTree()
        let b = tree.split(PaneID(0), orientation: .horizontal)! // [0, b]
        let c = tree.split(b, orientation: .horizontal)!         // [0, b, c]
        #expect(tree.paneIDs == [PaneID(0), b, c])
    }
}
