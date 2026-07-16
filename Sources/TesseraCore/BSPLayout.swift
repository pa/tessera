import CoreGraphics

// MARK: - Pane identity

/// Stable identifier for a leaf pane. Callers (or `LayoutTree`) assign these;
/// the layout math never invents them, which keeps frame computation pure and
/// tests deterministic.
public struct PaneID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let value: Int
    public init(_ value: Int) { self.value = value }
    public var description: String { "pane#\(value)" }
}

// MARK: - Split orientation

/// How a split arranges its two children.
///
/// Named by the *arrangement direction* to avoid the classic tmux ambiguity:
/// - `.horizontal` places children left → right, dividing the **width**.
/// - `.vertical`   places children top → bottom, dividing the **height**.
///
/// `first` is the left/top child; `second` is the right/bottom child. `ratio`
/// is the fraction of the divisible extent given to `first`.
public enum SplitOrientation: Sendable, Codable {
    case horizontal
    case vertical

    /// Split `rect` into two sibling rects, reserving `gap` points of empty
    /// space between them. Works in top-left-origin space (y grows downward),
    /// so the `.vertical` `first` child is the topmost.
    func divide(_ rect: CGRect, ratio: CGFloat, gap: CGFloat) -> (CGRect, CGRect) {
        switch self {
        case .horizontal:
            let usable = max(0, rect.width - gap)
            let w1 = usable * ratio
            let w2 = usable - w1
            let first = CGRect(x: rect.minX, y: rect.minY, width: w1, height: rect.height)
            let second = CGRect(x: rect.minX + w1 + gap, y: rect.minY, width: w2, height: rect.height)
            return (first, second)
        case .vertical:
            let usable = max(0, rect.height - gap)
            let h1 = usable * ratio
            let h2 = usable - h1
            let first = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h1)
            let second = CGRect(x: rect.minX, y: rect.minY + h1 + gap, width: rect.width, height: h2)
            return (first, second)
        }
    }
}

// MARK: - Insets / configuration

/// Per-window trim applied inside each pane's cell — the brief's "titlebar /
/// border insets" knob. A macOS window frame set via AX includes its titlebar,
/// so trimming here lets a layout reserve space (e.g. shave the shadow, or
/// leave a strip) without distorting the tiling math.
public struct EdgeInsets: Equatable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top; self.left = left; self.bottom = bottom; self.right = right
    }

    public static let zero = EdgeInsets()

    public init(uniform value: CGFloat) {
        self.init(top: value, left: value, bottom: value, right: value)
    }
}

/// Tunables for turning a BSP tree into concrete window frames.
public struct LayoutConfig: Equatable, Sendable {
    /// Uniform margin between the workspace edge and the outermost panes.
    public var outerGap: CGFloat
    /// Empty space reserved between two sibling panes at every split.
    public var innerGap: CGFloat
    /// Trim applied inside each leaf's cell before it becomes a window frame.
    public var windowInsets: EdgeInsets

    public init(outerGap: CGFloat = 0, innerGap: CGFloat = 0, windowInsets: EdgeInsets = .zero) {
        self.outerGap = outerGap
        self.innerGap = innerGap
        self.windowInsets = windowInsets
    }

    public static let tight = LayoutConfig()
}

// MARK: - BSP tree

/// A Binary Space Partitioning tree: every node is either a leaf pane or a
/// split of two children. Pure value type — all mutations return a new tree, so
/// it's trivially testable and free of the window server's state.
public indirect enum BSPNode: Sendable, Codable {
    case leaf(PaneID)
    case split(orientation: SplitOrientation, ratio: CGFloat, first: BSPNode, second: BSPNode)

    /// Ratios are clamped to this range so a split can never produce a
    /// zero-extent pane that no window could occupy.
    public static let ratioBounds: ClosedRange<CGFloat> = 0.05...0.95

    /// Leaf ids in left-to-right / top-to-bottom traversal order.
    public var leafIDs: [PaneID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, _, let a, let b):
            return a.leafIDs + b.leafIDs
        }
    }

    public func contains(_ id: PaneID) -> Bool {
        leafIDs.contains(id)
    }

    /// Replace the leaf `target` with a split of `[target, newPane]`. Returns an
    /// unchanged tree if `target` isn't present. Non-`target` leaves and the
    /// overall structure are preserved.
    public func splitting(
        _ target: PaneID,
        into newPane: PaneID,
        orientation: SplitOrientation,
        ratio: CGFloat = 0.5
    ) -> BSPNode {
        let r = ratio.clamped(to: BSPNode.ratioBounds)
        switch self {
        case .leaf(let id):
            guard id == target else { return self }
            return .split(orientation: orientation, ratio: r,
                          first: .leaf(id), second: .leaf(newPane))
        case .split(let o, let existing, let a, let b):
            return .split(orientation: o, ratio: existing,
                          first: a.splitting(target, into: newPane, orientation: orientation, ratio: r),
                          second: b.splitting(target, into: newPane, orientation: orientation, ratio: r))
        }
    }

    /// Remove leaf `target`, collapsing its parent split so the sibling takes
    /// the parent's place. Returns nil only if the whole tree was a single leaf
    /// equal to `target` (i.e. nothing left).
    public func removing(_ target: PaneID) -> BSPNode? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self
        case .split(let o, let ratio, let a, let b):
            let na = a.removing(target)
            let nb = b.removing(target)
            switch (na, nb) {
            case (nil, let survivor?), (let survivor?, nil):
                return survivor
            case (nil, nil):
                return nil
            case (let x?, let y?):
                return .split(orientation: o, ratio: ratio, first: x, second: y)
            }
        }
    }

    /// Set the split ratio of the node whose `first` subtree contains `target`
    /// / whose immediate split governs it. Resizes the nearest ancestor split
    /// of `target`. Returns an unchanged tree if `target` isn't found.
    public func resizing(_ target: PaneID, toRatio ratio: CGFloat) -> BSPNode {
        let r = ratio.clamped(to: BSPNode.ratioBounds)
        switch self {
        case .leaf:
            return self
        case .split(let o, let existing, let a, let b):
            if a.contains(target) && a.isLeaf(target) || b.contains(target) && b.isLeaf(target) {
                // `target` is an immediate child of this split — adjust here.
                return .split(orientation: o, ratio: r, first: a, second: b)
            }
            return .split(orientation: o, ratio: existing,
                          first: a.resizing(target, toRatio: r),
                          second: b.resizing(target, toRatio: r))
        }
    }

    private func isLeaf(_ id: PaneID) -> Bool {
        if case .leaf(let leafID) = self { return leafID == id }
        return false
    }

    /// Number of leaf panes under this node.
    var leafCount: Int {
        switch self {
        case .leaf: return 1
        case .split(_, _, let a, let b): return a.leafCount + b.leafCount
        }
    }

    /// Rebalance so every leaf pane ends up the same size: each split's ratio is
    /// set to the fraction of leaves in its first subtree (so a split feeding a
    /// 2-leaf subtree and a 1-leaf subtree gets ratio 2/3). Equivalent to
    /// AeroSpace's "balance-sizes".
    public func balanced() -> BSPNode {
        switch self {
        case .leaf:
            return self
        case .split(let orientation, _, let a, let b):
            let ratio = CGFloat(a.leafCount) / CGFloat(a.leafCount + b.leafCount)
            return .split(orientation: orientation,
                          ratio: ratio.clamped(to: BSPNode.ratioBounds),
                          first: a.balanced(), second: b.balanced())
        }
    }

    /// Grow or shrink the pane `target` along an axis by `delta` (a ratio
    /// fraction), adjusting the nearest ancestor split of that orientation —
    /// whichever side the pane sits on. Unlike a directional resize, this always
    /// works as long as the pane has *a* sibling along that axis, matching the
    /// intuitive i3 "grow/shrink width/height".
    ///
    /// `axis == .horizontal` resizes width; `.vertical` resizes height.
    public func resized(_ target: PaneID, axis: SplitOrientation, grow: Bool, by delta: CGFloat) -> BSPNode {
        var adjusted = false

        func recurse(_ node: BSPNode) -> (node: BSPNode, containsTarget: Bool) {
            switch node {
            case .leaf(let id):
                return (node, id == target)
            case .split(let orientation, let ratio, let a, let b):
                let left = recurse(a)
                let right = recurse(b)
                var newRatio = ratio
                if !adjusted, orientation == axis {
                    if left.containsTarget {
                        // Target is the first child; growing it raises the ratio.
                        newRatio = (ratio + (grow ? delta : -delta)).clamped(to: BSPNode.ratioBounds)
                        adjusted = true
                    } else if right.containsTarget {
                        // Target is the second child; its size is (1 - ratio), so
                        // growing it lowers the ratio.
                        newRatio = (ratio + (grow ? -delta : delta)).clamped(to: BSPNode.ratioBounds)
                        adjusted = true
                    }
                }
                return (.split(orientation: orientation, ratio: newRatio, first: left.node, second: right.node),
                        left.containsTarget || right.containsTarget)
            }
        }
        return recurse(self).node
    }

    /// Grow the pane `target` toward `direction` by `delta` (a ratio fraction),
    /// by nudging the split ratio of the *nearest* ancestor split along that
    /// axis on the correct side. No-op if the pane has no adjustable border in
    /// that direction (e.g. it's already flush against that edge of the screen).
    ///
    /// "Grow right/down" moves the divider on the far side of the pane outward;
    /// it requires the pane to sit in a split's `first` subtree. "Grow
    /// left/up" requires it in the `second` subtree. This mirrors the intuitive
    /// i3/AeroSpace "resize in a direction".
    public func resized(_ target: PaneID, _ direction: PaneNavigation.Direction, by delta: CGFloat) -> BSPNode {
        let axis: SplitOrientation = (direction == .left || direction == .right) ? .horizontal : .vertical
        // For right/down the target must be the first (left/top) child and the
        // ratio increases; for left/up it must be the second child and the ratio
        // decreases.
        let growFirst = (direction == .right || direction == .down)
        let ratioDelta = growFirst ? delta : -delta
        var adjusted = false

        func recurse(_ node: BSPNode) -> (node: BSPNode, containsTarget: Bool) {
            switch node {
            case .leaf(let id):
                return (node, id == target)
            case .split(let orientation, let ratio, let a, let b):
                let left = recurse(a)
                let right = recurse(b)
                var newRatio = ratio
                if !adjusted, orientation == axis {
                    if growFirst, left.containsTarget {
                        newRatio = (ratio + ratioDelta).clamped(to: BSPNode.ratioBounds)
                        adjusted = true
                    } else if !growFirst, right.containsTarget {
                        newRatio = (ratio + ratioDelta).clamped(to: BSPNode.ratioBounds)
                        adjusted = true
                    }
                }
                return (.split(orientation: orientation, ratio: newRatio, first: left.node, second: right.node),
                        left.containsTarget || right.containsTarget)
            }
        }
        return recurse(self).node
    }

    /// Compute the window frame for every leaf, given the workspace `rect` and
    /// `config`. This is the engine's whole reason for existing: turn the tree
    /// into exact x/y/width/height for each pane.
    public func frames(in rect: CGRect, config: LayoutConfig = .tight) -> [PaneID: CGRect] {
        var result: [PaneID: CGRect] = [:]
        let workspace = rect.insetBy(dx: config.outerGap, dy: config.outerGap)
        layout(in: workspace, config: config, into: &result)
        return result
    }

    private func layout(in rect: CGRect, config: LayoutConfig, into result: inout [PaneID: CGRect]) {
        switch self {
        case .leaf(let id):
            result[id] = rect.applying(insets: config.windowInsets)
        case .split(let orientation, let ratio, let a, let b):
            let (r1, r2) = orientation.divide(rect, ratio: ratio, gap: config.innerGap)
            a.layout(in: r1, config: config, into: &result)
            b.layout(in: r2, config: config, into: &result)
        }
    }
}

// MARK: - LayoutTree (ergonomic wrapper)

/// A workspace's live BSP tree plus a monotonic id allocator. Wraps `BSPNode`
/// so callers can split/remove without hand-managing pane ids. Starts as a
/// single pane (`PaneID(0)`) filling the workspace.
public struct LayoutTree: Sendable, Codable {
    public private(set) var root: BSPNode
    private var nextValue: Int

    public init() {
        self.root = .leaf(PaneID(0))
        self.nextValue = 1
    }

    public var paneIDs: [PaneID] { root.leafIDs }

    /// Split `target`, returning the id of the newly-created pane (or nil if
    /// `target` wasn't in the tree, in which case nothing changed).
    @discardableResult
    public mutating func split(
        _ target: PaneID,
        orientation: SplitOrientation,
        ratio: CGFloat = 0.5
    ) -> PaneID? {
        guard root.contains(target) else { return nil }
        let newPane = PaneID(nextValue)
        nextValue += 1
        root = root.splitting(target, into: newPane, orientation: orientation, ratio: ratio)
        return newPane
    }

    /// Remove `target`. No-op when it's the last remaining pane (a workspace
    /// always keeps at least one).
    public mutating func remove(_ target: PaneID) {
        if let newRoot = root.removing(target) {
            root = newRoot
        }
    }

    public mutating func resize(_ target: PaneID, toRatio ratio: CGFloat) {
        root = root.resizing(target, toRatio: ratio)
    }

    /// Grow `target` toward `direction` by `delta` (ratio fraction).
    public mutating func resize(_ target: PaneID, _ direction: PaneNavigation.Direction, by delta: CGFloat) {
        root = root.resized(target, direction, by: delta)
    }

    /// Grow/shrink `target`'s width (`.horizontal`) or height (`.vertical`).
    public mutating func resize(_ target: PaneID, axis: SplitOrientation, grow: Bool, by delta: CGFloat) {
        root = root.resized(target, axis: axis, grow: grow, by: delta)
    }

    /// Equalize all pane sizes.
    public mutating func balance() {
        root = root.balanced()
    }

    public func frames(in rect: CGRect, config: LayoutConfig = .tight) -> [PaneID: CGRect] {
        root.frames(in: rect, config: config)
    }
}

// MARK: - Helpers

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension CGRect {
    /// Shrink the rect by per-edge insets (top/bottom act on y in a
    /// top-left-origin space).
    func applying(insets: EdgeInsets) -> CGRect {
        CGRect(
            x: minX + insets.left,
            y: minY + insets.top,
            width: max(0, width - insets.left - insets.right),
            height: max(0, height - insets.top - insets.bottom)
        )
    }
}
