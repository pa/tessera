import Testing
import CoreGraphics
@testable import TesseraCore

private let workspace = CGRect(x: 0, y: 0, width: 900, height: 800)

@Suite("BSP balance")
struct BSPBalanceTests {

    @Test("Balancing an unbalanced 3-pane row gives three equal widths")
    func balanceThreePanes() {
        var tree = LayoutTree()
        // 0 | 1, then split 1 → 1 | 2 : a right-leaning chain (unequal by default).
        let right = tree.split(PaneID(0), orientation: .horizontal)!
        let third = tree.split(right, orientation: .horizontal, ratio: 0.5)!

        tree.balance()
        let frames = tree.frames(in: workspace)
        // Three equal columns of 300 each.
        #expect(abs((frames[PaneID(0)]?.width ?? 0) - 300) < 0.5)
        #expect(abs((frames[right]?.width ?? 0) - 300) < 0.5)
        #expect(abs((frames[third]?.width ?? 0) - 300) < 0.5)
    }

    @Test("Balancing a single pane is a no-op")
    func balanceSingle() {
        var tree = LayoutTree()
        tree.balance()
        #expect(tree.frames(in: workspace)[PaneID(0)] == workspace)
    }

    @Test("leafCount counts panes")
    func leafCount() {
        var tree = LayoutTree()
        _ = tree.split(PaneID(0), orientation: .horizontal)
        _ = tree.split(PaneID(1), orientation: .vertical)
        #expect(tree.root.leafCount == 3)
    }
}
