import CoreGraphics

/// Directional focus movement between panes — the vim/tmux "move focus left /
/// down / up / right" behaviour. Pure geometry over the computed frames, so it
/// works for any BSP layout and is unit-testable without the window server.
public enum PaneNavigation {
    public enum Direction: Sendable {
        case left, right, up, down
    }

    /// The pane adjacent to `pane` in `direction`, or nil if there is none.
    ///
    /// A candidate must lie on the correct side *and* share some perpendicular
    /// extent with the source (so "right" from a tall left pane lands on a pane
    /// that actually sits beside it). Among candidates the nearest one wins:
    /// smallest gap along the travel axis first, then closest perpendicular
    /// center.
    public static func adjacent(
        to pane: PaneID,
        in frames: [PaneID: CGRect],
        direction: Direction
    ) -> PaneID? {
        guard let source = frames[pane] else { return nil }

        var best: PaneID?
        var bestScore = CGFloat.greatestFiniteMagnitude

        for (id, rect) in frames where id != pane {
            let gap: CGFloat
            let overlap: CGFloat
            let centerDistance: CGFloat

            switch direction {
            case .right:
                guard rect.minX >= source.maxX - 1 else { continue }
                gap = rect.minX - source.maxX
                overlap = verticalOverlap(source, rect)
                centerDistance = abs(source.midY - rect.midY)
            case .left:
                guard rect.maxX <= source.minX + 1 else { continue }
                gap = source.minX - rect.maxX
                overlap = verticalOverlap(source, rect)
                centerDistance = abs(source.midY - rect.midY)
            case .down:
                guard rect.minY >= source.maxY - 1 else { continue }
                gap = rect.minY - source.maxY
                overlap = horizontalOverlap(source, rect)
                centerDistance = abs(source.midX - rect.midX)
            case .up:
                guard rect.maxY <= source.minY + 1 else { continue }
                gap = source.minY - rect.maxY
                overlap = horizontalOverlap(source, rect)
                centerDistance = abs(source.midX - rect.midX)
            }

            // Must actually sit beside the source, not merely diagonal.
            guard overlap > 0 else { continue }

            // Gap dominates (pick the nearest column/row); center distance breaks ties.
            let score = max(0, gap) * 1_000_000 + centerDistance
            if score < bestScore {
                bestScore = score
                best = id
            }
        }
        return best
    }

    private static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(a.maxY, b.maxY) - max(a.minY, b.minY)
    }

    private static func horizontalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(a.maxX, b.maxX) - max(a.minX, b.minX)
    }
}
