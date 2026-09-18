import Foundation

/// The longest remaining chain of blocked-by dependencies inside each goal.
///
/// Weight is unmet criteria rather than tasks, so the answer is the real
/// question: which chain of unfinished checks is holding this goal, and what
/// is the first link a person or an agent can pick up right now.
///
/// The Swift port of `critical_path` in `store/substrate_store.py`.
public struct CriticalPath {
    public struct Step {
        public let id: String
        public let title: String
        public let state: String
        public let openCriteria: Int
    }

    public let goal: String
    public let title: String
    public let cost: Int
    public let path: [Step]
    /// The first link anyone can pick up right now, if there is one.
    public let next: String?
    /// The first link in the chain, ready or not. Nil when the chain is empty.
    public let head: String?
    public let blocked: Bool
}

public extension Substrate {

    func criticalPath() throws -> [CriticalPath] {
        let all = try db.run("SELECT * FROM nodes WHERE removed=0").map(Node.init)
        let nodes = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

        var weight = Dictionary(uniqueKeysWithValues: all.map { ($0.id, 0) })
        for c in try criteria() where c.state != "met" {
            if weight[c.node] != nil { weight[c.node]! += 1 }
        }
        let pending = all.filter { $0.state != "done" }
        // A pending node with every check met still costs something: it is a
        // link in the chain, and a zero would let a longer chain hide behind it.
        for n in pending { weight[n.id] = max(weight[n.id] ?? 0, 1) }

        let pendingIDs = Set(pending.map(\.id))
        var successors: [String: [String]] = [:]
        for e in try db.run("SELECT blocker, blocked FROM edges") {
            guard let from = e["blocker"]?.string, let to = e["blocked"]?.string,
                  pendingIDs.contains(from), pendingIDs.contains(to) else { continue }
            successors[from, default: []].append(to)
        }

        var best: [String: (Int, [String])] = [:]
        var walking = Set<String>()
        func longest(_ id: String) -> (Int, [String]) {
            if let done = best[id] { return done }
            // A cycle should be impossible in a DAG. Refuse to hang if one
            // ever appears.
            if walking.contains(id) { return (0, []) }
            walking.insert(id)
            let own = weight[id] ?? 0
            var cost = own, path = [id]
            for s in successors[id] ?? [] {
                let (c, p) = longest(s)
                if c > cost - own { cost = own + c; path = [id] + p }
            }
            walking.remove(id)
            best[id] = (cost, path)
            return (cost, path)
        }

        func goalOf(_ id: String) -> String {
            var current = id
            for _ in 0..<32 {
                guard let p = nodes[current]?.parent, !p.isEmpty else { return current }
                current = p
            }
            return current
        }

        let ready = Set(try frontier())
        var out: [CriticalPath] = []
        for g in all.filter({ $0.isGoal }).sorted(by: { $0.id < $1.id }) {
            let kids = pending.filter { !$0.isGoal && goalOf($0.id) == g.id }
            guard !kids.isEmpty else {
                out.append(.init(goal: g.id, title: g.title, cost: 0, path: [],
                                 next: nil, head: nil, blocked: false))
                continue
            }
            // max() keeps the first of equal costs, the same as the Python's.
            var winner = longest(kids[0].id)
            for k in kids.dropFirst() {
                let candidate = longest(k.id)
                if candidate.0 > winner.0 { winner = candidate }
            }
            let (cost, ids) = winner
            let head = ids.first { ready.contains($0) }
            out.append(.init(
                goal: g.id, title: g.title, cost: cost,
                path: ids.map { id in
                    CriticalPath.Step(id: id, title: nodes[id]?.title ?? "",
                                      state: nodes[id]?.state ?? "idle",
                                      openCriteria: weight[id] ?? 0)
                },
                next: head, head: ids.first, blocked: head == nil))
        }
        return out
    }

    /// Send an agent's work back with a note, and let it try again.
    ///
    /// The task goes back to `working` rather than to `idle`, because idle is
    /// what the runner watches, and the runner would take it without the note.
    ///
    /// This writes the record. Handing the note to an agent is the Python's
    /// `worker_ai.py` and is still to be ported; see PORT-TO-SWIFT.md.
    func redo(node id: String, note: String, actor: String) throws {
        guard try node(id) != nil else {
            throw DB.Failure.refused("unknown node: \(id)")
        }
        let said = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if said.isEmpty {
            throw DB.Failure.refused("say what should change; a redo with no note is a rerun")
        }
        try append(event: id, to: "working", actor: actor,
                   note: "sent back: " + String(said.prefix(200)))
        try db.run("UPDATE nodes SET owner=? WHERE id=?", [s("agent 1 (again)"), s(id)])
    }
}
