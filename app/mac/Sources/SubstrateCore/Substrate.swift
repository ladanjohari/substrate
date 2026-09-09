import Foundation

/// The store: the record, and every rule about what is allowed.
///
/// This is the Swift port of `store/substrate_store.py`. The Python is still
/// there and still correct; `bin/substrate-compare` runs both against the same
/// database and fails if they answer differently. That is what makes this a
/// port rather than a rewrite.
///
/// Two rules, and they are the product:
///   1. A node cannot be done while any of its criteria is open.
///   2. A criterion cannot be met without evidence.
public struct Substrate {
    public static let states = ["idle", "working", "waiting", "error", "done"]
    public static let criterionStates = ["unmet", "met", "failed"]

    public let db: DB

    /// Where the record lives. `SUBSTRATE_DB` moves it, which is how one
    /// project keeps its own separate from anybody else's.
    ///
    /// This used to walk up from `CommandLine.arguments[0]`, which is only a
    /// path when you type one. Run through PATH it is the bare command name,
    /// so the walk started in whatever directory you happened to be standing
    /// in, found nothing, and quietly made a new empty record there. Somebody
    /// in that position sees an empty tree and concludes their work is gone.
    ///
    /// So: walk up from the executable itself, and if there is no record to be
    /// found, say so and name where it looked. Never invent one.
    public static func defaultPath() throws -> String {
        if let p = ProcessInfo.processInfo.environment["SUBSTRATE_DB"], !p.isEmpty {
            return p
        }
        let binary = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = binary.resolvingSymlinksInPath().deletingLastPathComponent()
        var looked: [String] = []
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("store/substrate.db")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
            looked.append(candidate.path)
            // Stop at the root. Foundation turns "/" into "/.." rather than
            // standing still, so walking past it lists paths nobody has.
            if dir.path == "/" { break }
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
        throw DB.Failure.refused("""
            no record found, and I will not make one where you happen to be standing.
            Point at it:  SUBSTRATE_DB=/path/to/substrate.db
            Looked in:
            \(looked.prefix(4).map { "  " + $0 }.joined(separator: "\n"))
            """)
    }

    public init(path: String? = nil) throws {
        db = try DB(path: path ?? (try Substrate.defaultPath()))
        try db.script(Substrate.schema)
        // The same migrations the Python applies, in the same order, so a
        // database made by either one opens in the other.
        for m in ["ALTER TABLE nodes ADD COLUMN runbook TEXT",
                  "ALTER TABLE nodes ADD COLUMN removed INTEGER NOT NULL DEFAULT 0",
                  "ALTER TABLE events ADD COLUMN criterion INTEGER"] {
            try? db.script(m)
        }
    }

    static let schema = """
    CREATE TABLE IF NOT EXISTS nodes (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      intent TEXT NOT NULL,
      exit_criterion TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'idle',
      owner TEXT,
      parent TEXT REFERENCES nodes(id),
      runbook TEXT
    );
    CREATE TABLE IF NOT EXISTS edges (
      blocker TEXT NOT NULL REFERENCES nodes(id),
      blocked TEXT NOT NULL REFERENCES nodes(id),
      PRIMARY KEY (blocker, blocked)
    );
    CREATE TABLE IF NOT EXISTS events (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      ts TEXT NOT NULL,
      actor TEXT NOT NULL,
      node TEXT NOT NULL REFERENCES nodes(id),
      from_state TEXT,
      to_state TEXT NOT NULL,
      note TEXT
    );
    CREATE TABLE IF NOT EXISTS criteria (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      node TEXT NOT NULL REFERENCES nodes(id),
      ord INTEGER NOT NULL DEFAULT 0,
      text TEXT NOT NULL,
      state TEXT NOT NULL DEFAULT 'unmet',
      evidence TEXT,
      checked_by TEXT,
      checked_at TEXT
    );
    CREATE INDEX IF NOT EXISTS criteria_by_node ON criteria(node, ord);
    """

    /// The same shape of timestamp the Python writes, so a log written by one
    /// reads in the other.
    public static func now() -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date()).replacingOccurrences(of: "Z", with: "+00:00")
    }

    // MARK: - reading

    public func criteria(of node: String? = nil) throws -> [Criterion] {
        let rows = node == nil
            ? try db.run("SELECT * FROM criteria ORDER BY node, ord, id")
            : try db.run("SELECT * FROM criteria WHERE node=? ORDER BY ord, id", [s(node!)])
        return rows.map(Criterion.init)
    }

    public func unmet(_ node: String) throws -> [Criterion] {
        try db.run("SELECT * FROM criteria WHERE node=? AND state!='met' ORDER BY ord, id",
                   [s(node)]).map(Criterion.init)
    }

    public func node(_ id: String) throws -> Node? {
        try db.run("SELECT * FROM nodes WHERE id=? AND removed=0", [s(id)]).first.map(Node.init)
    }

    public func tree() throws -> Tree {
        var nodes = try db.run("SELECT * FROM nodes WHERE removed=0 ORDER BY id").map(Node.init)
        let edges = try db.run("""
            SELECT e.* FROM edges e
            JOIN nodes a ON a.id=e.blocker JOIN nodes b ON b.id=e.blocked
            WHERE a.removed=0 AND b.removed=0
            """).map { Edge(blocker: $0["blocker"]?.string ?? "",
                            blocked: $0["blocked"]?.string ?? "") }
        var byNode: [String: [Criterion]] = [:]
        for c in try criteria() { byNode[c.node, default: []].append(c) }
        for k in nodes.indices { nodes[k].attach(byNode[nodes[k].id] ?? []) }
        return Tree(nodes: nodes, edges: edges)
    }

    /// Walks up to the goal, however deep the task is.
    public func rootGoal(of id: String) throws -> String {
        var current = id
        for _ in 0..<32 {
            guard let n = try node(current), let p = n.parent, !p.isEmpty else { return current }
            current = p
        }
        return current
    }

    // MARK: - the two rules

    /// Move a node. Refuses `done` while any criterion is open.
    @discardableResult
    public func append(event node: String, to state: String,
                       actor: String, note: String? = nil) throws -> Node {
        guard Substrate.states.contains(state) else {
            throw DB.Failure.refused("unknown state: \(state)")
        }
        guard let existing = try self.node(node) else {
            throw DB.Failure.refused("unknown node: \(node)")
        }
        if state == "done" {
            // The one rule that makes done trustable: a node is done when its
            // criteria say so, not when an agent asserts it.
            let all = try criteria(of: node)
            if all.isEmpty {
                throw DB.Failure.refused("\(node) has no exit criteria; add one before closing it")
            }
            let open = try unmet(node)
            if !open.isEmpty {
                // One criterion per line. A person reads this to decide what
                // to do next, and a single long line is unreadable.
                let word = open.count == 1 ? "criterion" : "criteria"
                let names = open.map { "\n        #\($0.id) \($0.text)" }.joined()
                throw DB.Failure.refused(
                    "\(node) cannot be done: \(open.count) \(word) still open\(names)")
            }
        }
        try db.transaction {
            try db.run("""
                INSERT INTO events (ts, actor, node, from_state, to_state, note)
                VALUES (?,?,?,?,?,?)
                """, [s(Substrate.now()), s(actor), s(node), s(existing.state), s(state), s(note)])
            try db.run("UPDATE nodes SET state=? WHERE id=?", [s(state), s(node)])
            if state != "working" {
                // The owner is who holds it right now. A task that stopped is
                // held by nobody, and a stale name there would have the display
                // claiming an agent is on something it walked away from.
                try db.run("UPDATE nodes SET owner=NULL WHERE id=?", [s(node)])
            }
        }
        // Not a force unwrap: another process can flag this row removed
        // between the commit and this read, and a library should say so
        // rather than trap.
        guard let after = try self.node(node) else {
            throw DB.Failure.refused("\(node) was removed while it was being moved to \(state)")
        }
        return after
    }

    public struct CriterionResult {
        public let criterion: Int
        public let node: String
        public let state: String
        /// True when nothing is left open, so the node can now be closed.
        public let nodeClosable: Bool
    }

    /// Move a criterion. Refuses `met` with no evidence.
    @discardableResult
    public func set(criterion cid: Int, to state: String,
                    actor: String, evidence: String? = nil) throws -> CriterionResult {
        guard Substrate.criterionStates.contains(state) else {
            throw DB.Failure.refused(
                "unknown criterion state: \(state) (use \(Substrate.criterionStates.joined(separator: "/")))")
        }
        guard let row = try db.run("SELECT * FROM criteria WHERE id=?", [i(cid)]).first else {
            throw DB.Failure.refused("unknown criterion: \(cid)")
        }
        let c = Criterion(row)
        if state == "met" && (evidence ?? "").isEmpty {
            // Met without evidence is exactly the vibes-based done this system
            // exists to replace.
            throw DB.Failure.refused("meeting a criterion requires evidence: what shows it is true?")
        }
        let nodeState = try node(c.node)?.state ?? "idle"
        try db.transaction {
            try db.run("""
                UPDATE criteria SET state=?, evidence=?, checked_by=?, checked_at=? WHERE id=?
                """, [s(state), s(evidence), s(actor), s(Substrate.now()), i(cid)])
            let note = "criterion \(c.state) -> \(state): \(c.text)"
                + (evidence.map { " | evidence: \($0)" } ?? "")
            try db.run("""
                INSERT INTO events (ts, actor, node, from_state, to_state, note, criterion)
                VALUES (?,?,?,?,?,?,?)
                """, [s(Substrate.now()), s(actor), s(c.node), s(nodeState), s(nodeState),
                      s(note), i(cid)])
        }
        return CriterionResult(criterion: cid, node: c.node, state: state,
                               nodeClosable: try unmet(c.node).isEmpty)
    }
}
