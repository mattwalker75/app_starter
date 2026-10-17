// Rearranging a bundle by drag and drop (Matt, Oct 16 2026: "click and hold on the application card and drag it"):
// a step (one app, or a whole sub-bundle) moves to another place in the order; an app moves into a sub-bundle, out
// of one, or from one to another. One pure function, tested on its own; the window only says what was dropped where.
import Foundation

/// What is being dragged.
public enum DragItem: Equatable, Sendable {
    case step(UUID)
    case app(UUID)

    /// "step:<id>" / "app:<id>" — the text a drag carries
    public var token: String {
        switch self { case .step(let id): return "step:\(id.uuidString)"; case .app(let id): return "app:\(id.uuidString)" }
    }
    public init?(token: String) {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] { case "step": self = .step(id); case "app": self = .app(id); default: return nil }
    }
}

/// Where it is dropped.
public enum DropTarget: Equatable, Sendable {
    /// in the step list, before the step at this index (the number of steps = at the end)
    case gap(Int)
    /// into this sub-bundle, before this app of it (nil = at its end)
    case intoGroup(UUID, before: UUID?)
}

extension AppBundle {
    /// The bundle with `item` moved to `target`, or nil when that changes nothing or isn't allowed (a sub-bundle
    /// can't go inside another). A one-app step keeps its id when it moves, so its place in a custom stop order stays.
    public func moving(_ item: DragItem, to target: DropTarget) -> AppBundle? {
        var b = self
        switch (item, target) {
        case (.step(let sid), .gap(let gap)):
            guard let from = b.steps.firstIndex(where: { $0.id == sid }) else { return nil }
            return b.moveStep(from: from, toGap: gap)

        case (.step(let sid), .intoGroup(let gid, let before)):
            // a one-app step dropped on a sub-bundle: its app goes in; a sub-bundle can't go inside another
            guard let s = b.steps.first(where: { $0.id == sid }), !s.isGroup, let app = s.apps.first else { return nil }
            return b.moving(.app(app.id), to: .intoGroup(gid, before: before))

        case (.app(let aid), .gap(let gap)):
            guard let si = b.stepIndex(of: aid) else { return nil }
            // the only app of its own step: the step itself moves
            if !b.steps[si].isGroup { return b.moveStep(from: si, toGap: gap) }
            // out of a sub-bundle (which stays, even if empty) into a step of its own at that place
            guard let ai = b.steps[si].apps.firstIndex(where: { $0.id == aid }) else { return nil }
            let app = b.steps[si].apps.remove(at: ai)
            b.steps.insert(Step(app: app), at: min(max(gap, 0), b.steps.count))
            return b

        case (.app(let aid), .intoGroup(let gid, let before)):
            guard before != aid, let si = b.stepIndex(of: aid), let ai = b.steps[si].apps.firstIndex(where: { $0.id == aid }),
                  let gIndex = b.steps.firstIndex(where: { $0.id == gid }), b.steps[gIndex].isGroup else { return nil }
            let app = b.steps[si].apps.remove(at: ai)
            if !b.steps[si].isGroup {
                // its one-app step goes away (and out of a custom stop order)
                let gone = b.steps.remove(at: si).id
                b.stopOrder?.removeAll { $0 == gone }
            }
            guard let gi = b.steps.firstIndex(where: { $0.id == gid }) else { return nil }
            let at = before.flatMap { id in b.steps[gi].apps.firstIndex { $0.id == id } } ?? b.steps[gi].apps.count
            b.steps[gi].apps.insert(app, at: at)
            return b == self ? nil : b
        }
    }

    /// Moves the step at `from` so it ends up before what is now at `gap` (gap = count: at the end).
    private mutating func moveStep(from: Int, toGap gap: Int) -> AppBundle? {
        let g = min(max(gap, 0), steps.count)
        // dropping just above or just below itself changes nothing
        if g == from || g == from + 1 { return nil }
        let s = steps.remove(at: from)
        steps.insert(s, at: g > from ? g - 1 : g)
        return self
    }
}
