import Foundation

/// Making a record, rather than reading one.
///
/// The Swift port of the write half of `store/substrate_store.py`. Everything
/// here writes the same rows, in the same order, with the same refusals, so
/// `bin/substrate-compare` can build one fixture through either implementation
/// and get the same database.
extension Substrate {

    public struct NewNode {
        public let id: String
        public let title: String
        public let intent: String
        public let criteria: [String]
        public let blockedBy: [String]
        public let note: String

        public init(id: String, title: String, intent: String? = nil,
                    criteria: [String], blockedBy: [String] = [],
                    note: String = "created on the canvas") {
            self.id = id
            self.title = title
            self.intent = (intent?.isEmpty == false ? intent! : title)
            self.criteria = criteria
            self.blockedBy = blockedBy
            self.note = note
        }

        /// Everything before the last slash, at any depth. Nil for a goal.
        public var parent: String? {
            guard let cut = id.lastIndex(of: "/") else { return nil }
            return String(id[id.startIndex..<cut])
        }
    }

    /// Create a node, its criteria and its blocking edges, in one transaction.
    ///
    /// Refuses a blank or spaced id, a missing parent, a duplicate, and a node
    /// with no exit criterion. That last one is the first rule stated at the
    /// point of creation: a thing nobody can check is not a task.
    @discardableResult
    public func add(_ n: NewNode, actor: String) throws -> Node {
        let id = n.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty || id.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            throw DB.Failure.refused(
                "an id is a short slug like 'ship-cli', or goal/slug for a task")
        }
        let texts = n.criteria
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if texts.isEmpty {
            throw DB.Failure.refused(
                "a node needs at least one exit criterion (-c \"what a stranger could check\")")
        }
        if let parent = n.parent, try node(parent) == nil {
            throw DB.Failure.refused("no such parent: \(parent)   (create it first)")
        }
        if try db.run("SELECT 1 FROM nodes WHERE id=?", [s(id)]).first != nil {
            throw DB.Failure.refused("node exists: \(id)")
        }
        try db.transaction {
            try db.run("""
                INSERT INTO nodes (id,title,intent,exit_criterion,parent) VALUES (?,?,?,?,?)
                """, [s(id), s(n.title), s(n.intent), s(texts[0]), s(n.parent)])
            for b in n.blockedBy {
                try db.run("INSERT OR IGNORE INTO edges (blocker,blocked) VALUES (?,?)",
                           [s(b), s(id)])
            }
            for (ord, text) in texts.enumerated() {
                try db.run("INSERT INTO criteria (node, ord, text) VALUES (?,?,?)",
                           [s(id), i(ord), s(text)])
            }
            try db.run("""
                INSERT INTO events (ts, actor, node, from_state, to_state, note)
                VALUES (?,?,?,?,?,?)
                """, [s(Substrate.now()), s(actor), s(id), .null, s("idle"), s(n.note)])
        }
        guard var made = try node(id) else {
            throw DB.Failure.refused("\(id) was removed while it was being created")
        }
        made.attachForDisplay(try criteria(of: id))
        return made
    }

    /// Add one criterion to a node that already exists. The ord continues from
    /// whatever is there, so the order a person wrote them in survives.
    @discardableResult
    public func add(criterion text: String, to id: String, actor: String) throws -> Int {
        guard try node(id) != nil else {
            throw DB.Failure.refused("unknown node: \(id)")
        }
        let state = try node(id)?.state ?? "idle"
        var cid = 0
        try db.transaction {
            let ord = try db.run(
                "SELECT COALESCE(MAX(ord)+1, 0) AS next FROM criteria WHERE node=?",
                [s(id)]).first?["next"]?.int ?? 0
            try db.run("INSERT INTO criteria (node, ord, text) VALUES (?,?,?)",
                       [s(id), i(ord), s(text)])
            cid = try db.run("SELECT last_insert_rowid() AS id").first?["id"]?.int ?? 0
            try db.run("""
                INSERT INTO events (ts, actor, node, from_state, to_state, note, criterion)
                VALUES (?,?,?,?,?,?,?)
                """, [s(Substrate.now()), s(actor), s(id), s(state), s(state),
                      s("criterion added: \(text)"), i(cid)])
        }
        return cid
    }

    /// One node waits on another. Both have to exist, and a node cannot wait
    /// on itself.
    public func block(_ blocked: String, after blocker: String, actor: String) throws {
        guard try node(blocked) != nil else {
            throw DB.Failure.refused("unknown node: \(blocked)")
        }
        guard try node(blocker) != nil else {
            throw DB.Failure.refused("unknown node: \(blocker)")
        }
        if blocked == blocker {
            throw DB.Failure.refused("\(blocked) cannot block itself")
        }
        // The blocker already waits on this node, directly or through others:
        // the edge would make a loop that nothing could ever finish.
        if try blockers(of: blocker).contains(blocked) {
            throw DB.Failure.refused(
                "\(blocker) already waits on \(blocked); that would be a loop")
        }
        let state = try node(blocked)?.state ?? "idle"
        try db.transaction {
            try db.run("INSERT OR IGNORE INTO edges (blocker,blocked) VALUES (?,?)",
                       [s(blocker), s(blocked)])
            try db.run("""
                INSERT INTO events (ts, actor, node, from_state, to_state, note)
                VALUES (?,?,?,?,?,?)
                """, [s(Substrate.now()), s(actor), s(blocked), s(state), s(state),
                      s("edge added: now blocked by \(blocker)")])
        }
    }

    public func unblock(_ blocked: String, from blocker: String, actor: String) throws {
        guard try db.run("SELECT 1 FROM edges WHERE blocker=? AND blocked=?",
                         [s(blocker), s(blocked)]).first != nil else {
            throw DB.Failure.refused("\(blocked) is not blocked by \(blocker)")
        }
        let state = try node(blocked)?.state ?? "idle"
        try db.transaction {
            try db.run("DELETE FROM edges WHERE blocker=? AND blocked=?",
                       [s(blocker), s(blocked)])
            try db.run("""
                INSERT INTO events (ts, actor, node, from_state, to_state, note)
                VALUES (?,?,?,?,?,?)
                """, [s(Substrate.now()), s(actor), s(blocked), s(state), s(state),
                      s("edge removed: no longer blocked by \(blocker)")])
        }
    }

    /// Everything that has to finish before this node can start, transitively.
    func blockers(of node: String, seen: inout Set<String>) throws {
        for row in try db.run("SELECT blocker FROM edges WHERE blocked=?", [s(node)]) {
            guard let b = row["blocker"]?.string, !seen.contains(b) else { continue }
            seen.insert(b)
            try blockers(of: b, seen: &seen)
        }
    }

    public func blockers(of node: String) throws -> Set<String> {
        var seen = Set<String>()
        try blockers(of: node, seen: &seen)
        return seen
    }

    /// Rewrite the words on a node. Only the three fields a person wrote.
    @discardableResult
    public func update(node id: String, actor: String,
                       title: String? = nil, intent: String? = nil,
                       exitCriterion: String? = nil) throws -> [String] {
        guard let before = try node(id) else {
            throw DB.Failure.refused("unknown node: \(id)")
        }
        // Ordered, so the note reads the same as the Python's.
        let fields: [(String, String)] = [
            ("title", title), ("intent", intent), ("exit_criterion", exitCriterion),
        ].compactMap { name, value in value.map { (name, $0) } }
        if fields.isEmpty {
            throw DB.Failure.refused("nothing to change: give -t, -i, or -e")
        }
        try db.transaction {
            for (column, value) in fields {
                try db.run("UPDATE nodes SET \(column)=? WHERE id=?", [s(value), s(id)])
                if column == "exit_criterion" {
                    // The node's headline criterion and criterion 0 are the
                    // same sentence, and they stay that way.
                    try db.run("UPDATE criteria SET text=? WHERE node=? AND ord=0",
                               [s(value), s(id)])
                }
            }
            try db.run("""
                INSERT INTO events (ts, actor, node, from_state, to_state, note)
                VALUES (?,?,?,?,?,?)
                """, [s(Substrate.now()), s(actor), s(id), s(before.state), s(before.state),
                      s("reshaped: " + fields.map { "\($0.0) rewritten" }
                          .joined(separator: ", "))])
        }
        return fields.map(\.0)
    }
}
