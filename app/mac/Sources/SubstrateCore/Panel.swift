import Foundation

/// Everything one look at the menu bar needs, in a single answer.
///
/// The app should not fetch the whole tree and work out what matters for
/// itself; that judgement would then live in two places and drift. This
/// answers the panel's actual question, what needs me and what is running,
/// and hands over the dots already ordered.
public struct PanelState {
    public struct Item {
        public let id: String
        public let title: String
        public let goal: String
        public let state: String
        public let owner: String?
        public let met: Int
        public let total: Int
        public let depth: Int
        public var openCriteria: [String] = []
        public var openIds: [Int] = []
        public var elapsed: String?
        public var after: [String] = []
    }

    public struct Proposed {
        public let id: String
        public let title: String
        public let tasks: [Item]
    }

    public struct Counts {
        public var needsYou = 0, running = 0, ready = 0
        public var done = 0, blocked = 0, unapprovedGoals = 0
    }

    public var asOf = ""
    public var goals: [(id: String, title: String, state: String)] = []
    public var needsYou: [Item] = []
    public var running: [Item] = []
    public var proposed: [Proposed] = []
    public var counts = Counts()
    public var dots: [String] = ["hollow"]
    public var overflow = 0
}

public extension Substrate {

    func panel() throws -> PanelState {
        let t = try tree()
        let tasks = t.tasks
        let goals = t.goals

        // A task with unfinished parts is not workable itself. Its parts are
        // how it gets done.
        let hasOpenKids = Set(t.nodes.compactMap { n -> String? in
            guard let p = n.parent, !p.isEmpty, n.state != "done" else { return nil }
            return p
        })
        let blockedBy = t.openBlockers()

        func slim(_ n: Node) throws -> PanelState.Item {
            PanelState.Item(
                id: n.id, title: n.title, goal: try rootGoal(of: n.id),
                state: n.state, owner: n.owner,
                met: n.criteriaMet, total: n.criteriaTotal,
                depth: n.id.filter { $0 == "/" }.count - 1)
        }

        var out = PanelState()
        out.asOf = Substrate.now()
        out.goals = goals.map { (id: $0.id, title: $0.title, state: $0.state) }

        for n in tasks where n.state == "waiting" {
            var item = try slim(n)
            // Ids as well as text: an app that can only show the checks is a
            // display. One that can close them is a tool.
            let open = n.criteria.filter { $0.state != "met" }
            item.openCriteria = open.map(\.text)
            item.openIds = open.map(\.id)
            out.needsYou.append(item)
        }

        for n in tasks where n.state == "working" {
            var item = try slim(n)
            item.elapsed = try elapsed(on: n.id)
            out.running.append(item)
        }

        let ready = tasks.filter {
            $0.state == "idle" && !hasOpenKids.contains($0.id) && blockedBy[$0.id] == nil
        }

        // A goal nobody has approved is a plan waiting to be read. The tasks
        // come with it, because approving without seeing what you are
        // approving is exactly the thing this gate exists to prevent.
        for g in goals where g.state == "waiting" {
            var kids: [Node] = []
            for n in tasks where try rootGoal(of: n.id) == g.id { kids.append(n) }
            let ordered = t.inRunOrder(kids, blockedBy: blockedBy)
            var items: [PanelState.Item] = []
            for n in ordered {
                var item = try slim(n)
                item.after = (blockedBy[n.id] ?? []).map {
                    $0.split(separator: "/").last.map(String.init) ?? $0
                }
                items.append(item)
            }
            out.proposed.append(.init(id: g.id, title: g.title, tasks: items))
        }

        out.counts = PanelState.Counts(
            needsYou: out.needsYou.count,
            running: out.running.count,
            ready: ready.count,
            done: tasks.filter { $0.state == "done" }.count,
            blocked: tasks.filter {
                $0.state == "idle" && (hasOpenKids.contains($0.id) || blockedBy[$0.id] != nil)
            }.count,
            unapprovedGoals: goals.filter { $0.state == "waiting" }.count)

        // The pill compresses the quiet, never the actionable: anything
        // needing a person comes before anything merely busy, and the overflow
        // count is what falls off the end.
        var order: [String] = []
        order += out.needsYou.map { _ in "needs" }
        order += out.running.map { _ in "working" }
        order += tasks.filter { $0.state == "error" }.map { _ in "error" }
        order += tasks.filter { $0.state == "done" }.map { _ in "done" }
        out.dots = order.isEmpty ? (tasks.isEmpty ? ["hollow"] : ["idle"])
                                 : Array(order.prefix(4))
        out.overflow = max(0, order.count - 4)
        return out
    }
}
