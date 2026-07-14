import Testing
import CoreGraphics
@testable import TesseraCore

@Suite("Pane navigation")
struct PaneNavigationTests {
    // A 2×2 grid of panes over a 1000×800 space:
    //   0 | 1
    //   --+--
    //   2 | 3
    private let grid: [PaneID: CGRect] = [
        PaneID(0): CGRect(x: 0, y: 0, width: 500, height: 400),
        PaneID(1): CGRect(x: 500, y: 0, width: 500, height: 400),
        PaneID(2): CGRect(x: 0, y: 400, width: 500, height: 400),
        PaneID(3): CGRect(x: 500, y: 400, width: 500, height: 400),
    ]

    @Test("Right moves to the pane on the right")
    func right() {
        #expect(PaneNavigation.adjacent(to: PaneID(0), in: grid, direction: .right) == PaneID(1))
        #expect(PaneNavigation.adjacent(to: PaneID(2), in: grid, direction: .right) == PaneID(3))
    }

    @Test("Left moves to the pane on the left")
    func left() {
        #expect(PaneNavigation.adjacent(to: PaneID(1), in: grid, direction: .left) == PaneID(0))
        #expect(PaneNavigation.adjacent(to: PaneID(3), in: grid, direction: .left) == PaneID(2))
    }

    @Test("Down moves to the pane below")
    func down() {
        #expect(PaneNavigation.adjacent(to: PaneID(0), in: grid, direction: .down) == PaneID(2))
        #expect(PaneNavigation.adjacent(to: PaneID(1), in: grid, direction: .down) == PaneID(3))
    }

    @Test("Up moves to the pane above")
    func up() {
        #expect(PaneNavigation.adjacent(to: PaneID(2), in: grid, direction: .up) == PaneID(0))
        #expect(PaneNavigation.adjacent(to: PaneID(3), in: grid, direction: .up) == PaneID(1))
    }

    @Test("No neighbor at the edge returns nil")
    func edges() {
        #expect(PaneNavigation.adjacent(to: PaneID(0), in: grid, direction: .left) == nil)
        #expect(PaneNavigation.adjacent(to: PaneID(0), in: grid, direction: .up) == nil)
        #expect(PaneNavigation.adjacent(to: PaneID(3), in: grid, direction: .right) == nil)
        #expect(PaneNavigation.adjacent(to: PaneID(3), in: grid, direction: .down) == nil)
    }

    @Test("A full-height left pane picks the vertically-closest right neighbor")
    func tallNeighbor() {
        // Left pane spans full height; right column split into top/bottom.
        let frames: [PaneID: CGRect] = [
            PaneID(0): CGRect(x: 0, y: 0, width: 500, height: 800),   // tall left
            PaneID(1): CGRect(x: 500, y: 0, width: 500, height: 400), // top right
            PaneID(2): CGRect(x: 500, y: 400, width: 500, height: 400), // bottom right
        ]
        // From the tall left pane (center y=400), the top-right (center 200) and
        // bottom-right (center 600) are equidistant; the first-scanned wins
        // deterministically — assert it's one of the right-column panes.
        let target = PaneNavigation.adjacent(to: PaneID(0), in: frames, direction: .right)
        #expect(target == PaneID(1) || target == PaneID(2))
    }

    @Test("Diagonal-only panes are not reachable")
    func noDiagonal() {
        // Pane 3 (bottom-right) is diagonal from pane 0; not a direct neighbor.
        #expect(PaneNavigation.adjacent(to: PaneID(0), in: grid, direction: .right) != PaneID(3))
        #expect(PaneNavigation.adjacent(to: PaneID(0), in: grid, direction: .down) != PaneID(3))
    }
}
