import Foundation

/// What a node, a criterion and an edge are.
///
/// The same fields the Python writes, read from the same table, so the two
/// implementations can be pointed at one database and compared.
public struct Node: Equatable {
    public let id: String
    public let title: String
    public let intent: String
    public let exitCriterion: String
    public let state: String
    public let owner: String?
    public let parent: String?
    /// Real columns, carried so the JSON matches the Python's field for field.
    public let runbook: String?
    public let removed: Int

    public private(set) var criteria: [Criterion] = []
    public var criteriaMet: Int { criteria.filter { $0.state == "met" }.count }
    public var criteriaTotal: Int { criteria.count }
    public var criteriaFailed: Int { criteria.filter { $0.state == "failed" }.count }

    /// The short name, which is what you type. The id is a path.
    public var slug: String { id.split(separator: "/").last.map(String.init) ?? id }
    public var isGoal: Bool { parent == nil || parent!.isEmpty }

    public init(_ row: DB.Row) {
        id = row["id"]?.string ?? ""
        title = row["title"]?.string ?? ""
        intent = row["intent"]?.string ?? ""
        exitCriterion = row["exit_criterion"]?.string ?? ""
        state = row["state"]?.string ?? "idle"
        owner = row["owner"]?.string
        parent = row["parent"]?.string
        runbook = row["runbook"]?.string
        removed = row["removed"]?.int ?? 0
    }

    mutating func attach(_ cs: [Criterion]) { criteria = cs }

    /// The same, from outside the module, for a command that fetched the
    /// criteria separately rather than through the whole tree.
    public mutating func attachForDisplay(_ cs: [Criterion]) { criteria = cs }
}

public struct Criterion: Equatable {
    public let id: Int
    public let node: String
    public let ord: Int
    public let text: String
    public let state: String
    public let evidence: String?
    public let checkedBy: String?
    public let checkedAt: String?

    public init(_ row: DB.Row) {
        id = row["id"]?.int ?? 0
        node = row["node"]?.string ?? ""
        ord = row["ord"]?.int ?? 0
        text = row["text"]?.string ?? ""
        state = row["state"]?.string ?? "unmet"
        evidence = row["evidence"]?.string
        checkedBy = row["checked_by"]?.string
        checkedAt = row["checked_at"]?.string
    }
}

public struct Edge: Equatable {
    public let blocker: String
    public let blocked: String
    public init(blocker: String, blocked: String) {
        self.blocker = blocker
        self.blocked = blocked
    }
}

public struct Tree {
    public let nodes: [Node]
    public let edges: [Edge]

    public var goals: [Node] { nodes.filter(\.isGoal) }
    public var tasks: [Node] { nodes.filter { !$0.isGoal } }

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
    public func children(of id: String) -> [Node] { nodes.filter { $0.parent == id } }

    /// What each task waits on, ignoring blockers that are already done.
    public func openBlockers() -> [String: [String]] {
        let doneIds = Set(nodes.filter { $0.state == "done" }.map(\.id))
        var out: [String: [String]] = [:]
        for e in edges where !doneIds.contains(e.blocker) {
            out[e.blocked, default: []].append(e.blocker)
        }
        return out
    }

    /// Blockers before the things they block, so "after X" always points at a
    /// row above. The same order the Python and the window use.
    public func inRunOrder(_ group: [Node], blockedBy: [String: [String]]) -> [Node] {
        var left = Dictionary(uniqueKeysWithValues: group.map { ($0.id, $0) })
        var placed = Set<String>(), out: [Node] = []
        while !left.isEmpty {
            var ready = left.values.filter { n in
                (blockedBy[n.id] ?? []).allSatisfy { placed.contains($0) || left[$0] == nil }
            }
            if ready.isEmpty { ready = Array(left.values) }
            for n in ready.sorted(by: { $0.id < $1.id }) {
                out.append(n)
                placed.insert(n.id)
                left[n.id] = nil
            }
        }
        return out
    }
}
