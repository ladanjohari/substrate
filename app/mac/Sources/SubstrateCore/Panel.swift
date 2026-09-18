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
        /// Whether an agent left something written to read.
        public var hasOutput = false
        /// The title of the goal this belongs to, for a list that shows work
        /// out of its own context.
        public var goalTitle: String?
    }

    /// Whether work is actually being picked up, which is not the same as
    /// whether somebody once started a runner.
    public struct Runner {
        public let on: Bool
        public let ours: Bool
        public let note: String
        public let secondsAgo: Int?
        public let task: String?
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
    public var ready: [Item] = []
    public var closable: [Item] = []
    public var runner = Runner(on: false, ours: false, note: "never started",
                               secondsAgo: nil, task: nil)
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

        // Which goal each task belongs to, worked out once from the tree that
        // is already in memory. This used to call rootGoal(of:) per task,
        // which is a database query per level of depth, several hundred of
        // them on a real store, once a second while the panel is open.
        let parentOf = Dictionary(uniqueKeysWithValues:
            t.nodes.map { ($0.id, $0.parent ?? "") })
        func goalOf(_ id: String) -> String {
            var current = id
            for _ in 0..<32 {
                guard let p = parentOf[current], !p.isEmpty else { return current }
                current = p
            }
            return current
        }

        func slim(_ n: Node) -> PanelState.Item {
            PanelState.Item(
                id: n.id, title: n.title, goal: goalOf(n.id),
                state: n.state, owner: n.owner,
                met: n.criteriaMet, total: n.criteriaTotal,
                depth: n.id.filter { $0 == "/" }.count - 1)
        }

        var out = PanelState()
        out.asOf = Substrate.now()
        out.goals = goals.map { (id: $0.id, title: $0.title, state: $0.state) }

        for n in tasks where n.state == "waiting" {
            var item = slim(n)
            // Ids as well as text: an app that can only show the checks is a
            // display. One that can close them is a tool.
            let open = n.criteria.filter { $0.state != "met" }
            item.openCriteria = open.map(\.text)
            item.openIds = open.map(\.id)
            // The owner is cleared when an agent finishes, so asking "did an
            // agent touch this" by looking at the owner hid the writing
            // exactly when it was ready to be read.
            item.hasOutput = hasOutput(for: n.id)
            out.needsYou.append(item)
        }

        for n in tasks where n.state == "working" {
            var item = slim(n)
            item.elapsed = try elapsed(on: n.id)
            out.running.append(item)
        }

        // The same rule the agents use, rather than a second one that looks
        // similar. They disagreed: a filter here listed a task whose goal was
        // still unapproved, so the panel offered work no agent would take.
        let readyIds = try frontier()
        let byID = Dictionary(uniqueKeysWithValues: t.nodes.map { ($0.id, $0) })
        let ready = readyIds.compactMap { byID[$0] }

        // A goal nobody has approved is a plan waiting to be read. The tasks
        // come with it, because approving without seeing what you are
        // approving is exactly the thing this gate exists to prevent.
        for g in goals where g.state == "waiting" {
            let kids = tasks.filter { goalOf($0.id) == g.id }
            let ordered = t.inRunOrder(kids, blockedBy: blockedBy)
            var items: [PanelState.Item] = []
            for n in ordered {
                var item = slim(n)
                item.after = (blockedBy[n.id] ?? []).map {
                    $0.split(separator: "/").last.map(String.init) ?? $0
                }
                items.append(item)
            }
            out.proposed.append(.init(id: g.id, title: g.title, tasks: items))
        }

        out.ready = ready.map { n in
            var item = slim(n)
            item.goalTitle = byID[goalOf(n.id)]?.title ?? ""
            return item
        }

        // A goal whose tasks are all done is not done: it has its own checks,
        // and somebody has to answer them. Without this the last step of every
        // goal could only be taken from a terminal, which is not a thing to
        // ask of the person the app is for.
        for g in goals where g.state != "waiting" && g.state != "done" {
            let kids = tasks.filter { goalOf($0.id) == g.id }
            if kids.isEmpty || kids.contains(where: { $0.state != "done" }) { continue }
            var item = slim(g)
            let open = g.criteria.filter { $0.state != "met" }
            item.openCriteria = open.map(\.text)
            item.openIds = open.map(\.id)
            out.closable.append(item)
        }

        out.runner = runnerState()

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

    /// Where an agent's writing lands. `SUBSTRATE_OUTPUTS` moves it; otherwise
    /// it sits beside the record, which is where the Python keeps it.
    func outputsDirectory() -> URL {
        if let set = ProcessInfo.processInfo.environment["SUBSTRATE_OUTPUTS"], !set.isEmpty {
            return URL(fileURLWithPath: set)
        }
        return URL(fileURLWithPath: db.path).deletingLastPathComponent()
            .appendingPathComponent("outputs")
    }

    func hasOutput(for id: String) -> Bool {
        let name = id.replacingOccurrences(of: "/", with: "__") + ".md"
        return FileManager.default.fileExists(
            atPath: outputsDirectory().appendingPathComponent(name).path)
    }

    /// The runner writes a timestamp next to the record every few seconds. If
    /// that timestamp is recent, work is being picked up; if it is not,
    /// nothing is running whatever any page claims.
    func runnerState() -> PanelState.Runner {
        let beat = URL(fileURLWithPath: db.path + ".beat")
        guard let data = try? Data(contentsOf: beat) else {
            return .init(on: false, ours: false, note: "never started",
                         secondsAgo: nil, task: nil)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .init(on: false, ours: false, note: "unreadable",
                         secondsAgo: nil, task: nil)
        }
        let at = (obj["at"] as? Double) ?? 0
        let age = Date().timeIntervalSince1970 - at
        // "ours" means started by this process, and a command line that exits
        // never started anything. Only the app can answer it differently.
        return .init(on: age < 30, ours: false,
                     note: (obj["note"] as? String) ?? "",
                     secondsAgo: Int(age.rounded()), task: obj["task"] as? String)
    }
}
