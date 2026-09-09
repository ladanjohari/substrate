import Foundation

/// The questions worth asking of the record, and the answers the app and the
/// command line both use.
///
/// These live here rather than in either face. That is the whole reason for
/// the port: the frontier rule, the approval guard and the panel's judgement
/// about what needs a person exist once, and the compiler checks that both
/// callers use the same one.
public extension Substrate {

    // MARK: - what may run

    /// Tasks an agent is allowed to take right now.
    ///
    /// A task reaches the frontier only when it is idle, every blocker is
    /// done, it has no unfinished parts of its own, and its goal has been
    /// approved. Approval is what arms a plan, and it lives on the goal at the
    /// top, which may be several levels above a subtask.
    func frontier() throws -> [String] {
        let rows = try db.run("""
            SELECT n.id, n.parent FROM nodes n
            WHERE n.state='idle' AND n.removed=0
              AND NOT EXISTS (
                SELECT 1 FROM edges e JOIN nodes b ON b.id=e.blocker
                WHERE e.blocked=n.id AND b.removed=0 AND b.state != 'done')
              AND NOT EXISTS (
                SELECT 1 FROM nodes k
                WHERE k.parent=n.id AND k.removed=0 AND k.state != 'done')
            """)
        var out: [String] = []
        for r in rows {
            let id = r["id"]?.string ?? ""
            guard let parent = r["parent"]?.string, !parent.isEmpty else {
                out.append(id)
                continue
            }
            let goal = try rootGoal(of: id)
            if try node(goal)?.state != "waiting" { out.append(id) }
        }
        return out
    }

    // MARK: - answering a plan

    /// Release a plan to the agents. Until this, nothing runs.
    @discardableResult
    func approve(goal: String, actor: String, note: String? = nil) throws -> Node {
        guard let row = try node(goal) else {
            throw DB.Failure.refused("unknown goal: \(goal)")
        }
        if let parent = row.parent, !parent.isEmpty {
            throw DB.Failure.refused("\(goal) is a task; approve its goal: \(parent)")
        }
        if row.state != "waiting" {
            if row.state == "idle" || row.state == "working" {
                throw DB.Failure.refused("\(goal) is already open for work, it needs no approval")
            }
            throw DB.Failure.refused(
                "\(goal) is \(row.state), and only a plan waiting for you can be approved")
        }
        return try append(event: goal, to: "working", actor: actor,
                          note: note ?? "approved; the runner may start")
    }

    /// Throw a plan away. The rows are flagged, not deleted, so the log still
    /// says a plan was proposed and a person turned it down.
    @discardableResult
    func reject(goal: String, actor: String, note: String? = nil) throws -> [String] {
        guard let row = try node(goal) else {
            throw DB.Failure.refused("unknown goal: \(goal)")
        }
        if let parent = row.parent, !parent.isEmpty {
            throw DB.Failure.refused("\(goal) is a task, not a plan; reject its goal: \(parent)")
        }
        if row.state != "waiting" {
            throw DB.Failure.refused(
                "\(goal) is \(row.state), and only a plan waiting for you can be rejected")
        }
        let why = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return try remove(node: goal, actor: actor,
                          note: why.isEmpty ? "rejected" : "rejected: " + why)
    }

    /// Soft removal: the row stays, flagged, so the event log still makes
    /// sense. Removing a goal removes its tasks with it, since a task with no
    /// goal is not reachable from anywhere.
    @discardableResult
    func remove(node id: String, actor: String,
                note: String = "removed in negotiation") throws -> [String] {
        guard let row = try node(id) else {
            throw DB.Failure.refused("unknown node: \(id)")
        }
        var removed = [id]
        for kid in try db.run("SELECT id FROM nodes WHERE parent=? AND removed=0", [s(id)]) {
            removed += try remove(node: kid["id"]?.string ?? "", actor: actor,
                                  note: "removed with its goal \(id)")
        }
        try db.transaction {
            try db.run("UPDATE nodes SET removed=1 WHERE id=?", [s(id)])
            try db.run("""
                INSERT INTO events (ts, actor, node, from_state, to_state, note)
                VALUES (?,?,?,?,?,?)
                """, [s(Substrate.now()), s(actor), s(id), s(row.state), s(row.state), s(note)])
        }
        return removed
    }

    // MARK: - taking work

    /// Take a task for one agent, if nobody else has it.
    ///
    /// The condition is part of the write, so the check and the claim are one
    /// step. Two runners racing for the same task both run this; exactly one
    /// wins and the other is told it lost.
    func claim(node id: String, actor: String) throws -> Bool {
        try db.run("""
            UPDATE nodes SET state='working', owner=?
            WHERE id=? AND state='idle' AND (owner IS NULL OR owner='')
            """, [s(actor), s(id)])
        let changed = try db.run("SELECT changes() AS c").first?["c"]?.int ?? 0
        guard changed > 0 else { return false }
        try db.run("""
            INSERT INTO events (ts, actor, node, from_state, to_state, note)
            VALUES (?,?,?,?,?,?)
            """, [s(Substrate.now()), s(actor), s(id), s("idle"), s("working"),
                  s("claimed by \(actor)")])
        return true
    }

    // MARK: - how long

    /// How long the current agent has held this task, already formatted.
    func elapsed(on id: String) throws -> String? {
        let row = try db.run("""
            SELECT ts FROM events WHERE node=? AND to_state='working'
            ORDER BY seq DESC LIMIT 1
            """, [s(id)]).first
        guard let ts = row?["ts"]?.string else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let started = f.date(from: ts.replacingOccurrences(of: "+00:00", with: "Z"))
        else { return nil }
        let secs = Int(Date().timeIntervalSince(started))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h\((secs % 3600) / 60)m"
    }
}
