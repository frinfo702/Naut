import Foundation

/// A part of the window showing a note.
struct Pane: Identifiable, Equatable {
    let id = UUID()
    var note: URL?
}

/// What splitting and closing do to the sizes of the panes around.
enum PaneScaling: String, CaseIterable {
    /// Even shares in a split until one of its dividers is dragged; from
    /// then on that split keeps its sizes.
    case adaptive
    /// Even shares everywhere after every split, dragged or not.
    case even
    /// The split pane gives half its own space, and a closed one's goes
    /// to its neighbour: every other pane keeps its size.
    case keep

    var title: String {
        switch self {
        case .adaptive: "Adaptive"
        case .even: "Always even"
        case .keep: "Keep sizes"
        }
    }
}

/// Panes side by side or stacked, each with a share of the split's length.
/// Only the shares' ratios matter.
struct PaneSplit: Identifiable, Equatable {
    let id = UUID()
    /// Stacked, not side by side.
    var vertical: Bool
    var children: [PaneNode]
    var weights: [CGFloat]
    /// One of its dividers was dragged: its sizes are someone's choice.
    var resized = false

    /// Whether a pane added or taken out leaves the rest at even shares.
    fileprivate func evens(_ scaling: PaneScaling) -> Bool {
        scaling == .even || (scaling == .adaptive && !resized)
    }
}

/// The window's panes, as a tree of splits.
indirect enum PaneNode: Equatable {
    case pane(Pane)
    case split(PaneSplit)

    /// Every pane, in reading order.
    var panes: [Pane] {
        switch self {
        case .pane(let pane): [pane]
        case .split(let split): split.children.flatMap(\.panes)
        }
    }

    private func isPane(_ id: Pane.ID) -> Bool {
        if case .pane(let pane) = self { pane.id == id } else { false }
    }

    mutating func mapPanes(_ note: (Pane) -> URL?) {
        switch self {
        case .pane(var pane):
            pane.note = note(pane)
            self = .pane(pane)
        case .split(var split):
            for i in split.children.indices { split.children[i].mapPanes(note) }
            self = .split(split)
        }
    }

    /// Put `new` after the pane `id`. The panes of its split end at even
    /// shares, or the pane gives half its own space and the rest keep
    /// their sizes: see `PaneScaling`.
    mutating func split(_ id: Pane.ID, vertical: Bool, new: Pane, scaling: PaneScaling) {
        insert(new, after: id, vertical: vertical, scaling: scaling)
        if scaling == .even { evenOut() }
    }

    private mutating func insert(_ new: Pane, after id: Pane.ID, vertical: Bool, scaling: PaneScaling) {
        switch self {
        case .pane(let pane):
            guard pane.id == id else { return }
            self = .split(PaneSplit(vertical: vertical, children: [self, .pane(new)], weights: [1, 1]))
        case .split(var split):
            if split.vertical == vertical, let i = split.children.firstIndex(where: { $0.isPane(id) }) {
                split.weights[i] /= 2
                split.children.insert(.pane(new), at: i + 1)
                split.weights.insert(split.weights[i], at: i + 1)
                if split.evens(scaling) { split.weights = split.weights.map { _ in 1 } }
            } else {
                for i in split.children.indices {
                    split.children[i].insert(new, after: id, vertical: vertical, scaling: scaling)
                }
            }
            self = .split(split)
        }
    }

    /// Even shares in every split, as if no divider had been dragged.
    private mutating func evenOut() {
        guard case .split(var split) = self else { return }
        split.weights = split.weights.map { _ in 1 }
        split.resized = false
        for i in split.children.indices { split.children[i].evenOut() }
        self = .split(split)
    }

    /// Take the pane `id` out. The rest of its split end at even shares,
    /// or its space goes to the pane before it, or after if it was first.
    /// A split left with one child is that child.
    mutating func remove(_ id: Pane.ID, scaling: PaneScaling) {
        guard case .split(var split) = self else { return }
        if let i = split.children.firstIndex(where: { $0.isPane(id) }) {
            split.children.remove(at: i)
            let weight = split.weights.remove(at: i)
            split.weights[max(0, i - 1)] += weight
            if split.evens(scaling) { split.weights = split.weights.map { _ in 1 } }
            self = split.children.count == 1 ? split.children[0] : .split(split)
        } else {
            for i in split.children.indices { split.children[i].remove(id, scaling: scaling) }
            self = .split(split)
        }
    }

    /// Move a divider: the child before it gets `weight`, and the child
    /// after it the rest of what the two had. Neither goes below its
    /// least; where the two are already too small for that, nothing moves.
    mutating func resize(_ divider: Divider, to weight: CGFloat) {
        guard case .split(var split) = self else { return }
        let (index, next) = (divider.index, divider.next)
        if split.id == divider.split, split.weights.indices.contains(index), split.weights.indices.contains(next) {
            let pair = split.weights[index] + split.weights[next]
            let (low, high) = (divider.leastBefore, pair - divider.leastAfter)
            if low <= high {
                split.weights[index] = min(max(weight, low), high)
                split.weights[next] = pair - split.weights[index]
                split.resized = true
            }
        } else {
            for i in split.children.indices { split.children[i].resize(divider, to: weight) }
        }
        self = .split(split)
    }

    /// The least length the node can have, across or down, for each of
    /// its panes to be at least `pane`.
    private func least(vertical: Bool, gap: CGFloat, pane: CGSize) -> CGFloat {
        switch self {
        case .pane: return vertical ? pane.height : pane.width
        case .split(let split):
            let each = split.children.map { $0.least(vertical: vertical, gap: gap, pane: pane) }
            return split.vertical == vertical
                ? each.reduce(0, +) + gap * CGFloat(each.count - 1)
                : each.max() ?? 0
        }
    }

    // MARK: - Layout

    /// A pane and where it is.
    struct Placed: Identifiable {
        let pane: Pane
        let frame: CGRect
        /// The split it is in is stacked, and it is the first there:
        /// which way it leaves when closed.
        let vertical: Bool
        let first: Bool
        var id: Pane.ID { pane.id }
    }

    /// The gap between two panes, which drags to resize them.
    struct Divider: Identifiable {
        let split: PaneSplit.ID
        /// The children before and after it. Not always neighbours: a
        /// child whose panes all float is skipped.
        let index: Int
        let next: Int
        let vertical: Bool
        let frame: CGRect
        /// The share of the pane before it, and the points one share is.
        let weight: CGFloat
        let perWeight: CGFloat
        /// The least share the children before and after it can have.
        let leastBefore: CGFloat
        let leastAfter: CGFloat
        var id: String { "\(split)-\(index)" }
    }

    /// Where every pane and divider is when the tree fills `rect`. The
    /// panes in `floating` keep their place in the tree but take no room:
    /// the rest are laid out as if they weren't there.
    /// A divider stops where a pane would be smaller than `least`.
    func place(
        in rect: CGRect, gap: CGFloat, floating: Set<Pane.ID> = [], least: CGSize = .zero
    ) -> (panes: [Placed], dividers: [Divider]) {
        var panes: [Placed] = [], dividers: [Divider] = []
        place(in: rect, gap: gap, floating: floating, least: least, vertical: false, first: true, &panes, &dividers)
        return (panes, dividers)
    }

    private func place(
        in rect: CGRect, gap: CGFloat, floating: Set<Pane.ID>, least: CGSize, vertical: Bool, first: Bool,
        _ panes: inout [Placed], _ dividers: inout [Divider]
    ) {
        switch self {
        case .pane(let pane):
            if !floating.contains(pane.id) {
                panes.append(Placed(pane: pane, frame: rect, vertical: vertical, first: first))
            }
        case .split(let split):
            let shown = split.children.indices.filter { !split.children[$0].panes.allSatisfy { floating.contains($0.id) } }
            guard !shown.isEmpty else { return }
            let length = split.vertical ? rect.height : rect.width
            let perWeight = max(0, length - gap * CGFloat(shown.count - 1)) / shown.reduce(0) { $0 + split.weights[$1] }
            var start = split.vertical ? rect.minY : rect.minX
            for (n, i) in shown.enumerated() {
                let child = split.children[i]
                let size = split.weights[i] * perWeight
                let frame = split.vertical
                    ? CGRect(x: rect.minX, y: start, width: rect.width, height: size)
                    : CGRect(x: start, y: rect.minY, width: size, height: rect.height)
                child.place(
                    in: frame, gap: gap, floating: floating, least: least, vertical: split.vertical, first: n == 0,
                    &panes, &dividers
                )
                start += size
                if n < shown.count - 1, perWeight > 0 {
                    let after = split.children[shown[n + 1]]
                    dividers.append(Divider(
                        split: split.id, index: i, next: shown[n + 1], vertical: split.vertical,
                        frame: split.vertical
                            ? CGRect(x: rect.minX, y: start, width: rect.width, height: gap)
                            : CGRect(x: start, y: rect.minY, width: gap, height: rect.height),
                        weight: split.weights[i], perWeight: perWeight,
                        leastBefore: child.least(vertical: split.vertical, gap: gap, pane: least) / perWeight,
                        leastAfter: after.least(vertical: split.vertical, gap: gap, pane: least) / perWeight
                    ))
                }
                start += gap
            }
        }
    }
}
