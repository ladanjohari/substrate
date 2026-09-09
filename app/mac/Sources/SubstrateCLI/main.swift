import Foundation
import SubstrateCore

// The command line, on the Swift core.
//
// This is the port in progress. It covers reading the record and both rules,
// which is the part that has to be right; the rest of the Python's commands
// follow. `bin/substrate-compare` runs this and the Python against one
// database and fails if they answer differently, so the port can be checked
// rather than trusted.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("refused: " + message + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
let wantsJSON = args.contains("--json")
args.removeAll { $0 == "--json" }

func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

let evidence = flag("-e") ?? flag("--evidence")
let note = flag("-n") ?? flag("--note")
let actor = ProcessInfo.processInfo.environment["SUBSTRATE_ACTOR"] ?? NSUserName()

let store: Substrate
do { store = try Substrate() } catch { fail("\(error)") }

func emit(_ any: Any) {
    let data = try! JSONSerialization.data(withJSONObject: any,
                                           options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

/// The same shape the Python's `--json` prints, field for field, so the two
/// can be compared with a plain diff.
func json(_ c: Criterion) -> [String: Any] {
    [
        "id": c.id, "node": c.node, "ord": c.ord, "text": c.text, "state": c.state,
        "evidence": c.evidence as Any? ?? NSNull(),
        "checked_by": c.checkedBy as Any? ?? NSNull(),
        "checked_at": c.checkedAt as Any? ?? NSNull(),
    ]
}

func json(_ n: Node) -> [String: Any] {
    [
        "id": n.id, "title": n.title, "intent": n.intent,
        "exit_criterion": n.exitCriterion, "state": n.state,
        "owner": n.owner as Any? ?? NSNull(),
        "parent": n.parent as Any? ?? NSNull(),
        "criteria_met": n.criteriaMet, "criteria_total": n.criteriaTotal,
        "criteria_failed": n.criteriaFailed,
        "criteria": n.criteria.map(json),
        "runbook": n.runbook as Any? ?? NSNull(),
        "removed": n.removed,
    ]
}

/// Short names work anywhere a node is expected, the same as the Python.
func resolve(_ name: String) throws -> String {
    if try store.node(name) != nil { return name }
    let matches = try store.tree().nodes.filter { $0.slug == name }
    if matches.count == 1 { return matches[0].id }
    if matches.isEmpty { fail("no such node: \(name)") }
    fail("\(name) is ambiguous: " + matches.map(\.id).joined(separator: ", "))
}

let command = args.first ?? "tree"
if !args.isEmpty { args.removeFirst() }

do {
    switch command {
    case "tree":
        let t = try store.tree()
        let goals = args.first.map { g in t.goals.filter { $0.id == g } } ?? t.goals
        if wantsJSON {
            emit(goals.map { g -> [String: Any] in
                var out = json(g)
                out["tasks"] = t.tasks.filter { $0.id.hasPrefix(g.id + "/") }.map(json)
                return out
            })
        } else {
            let blocked = t.openBlockers()
            for g in goals {
                print("\(g.title)   \(g.id)")
                let kids = t.tasks.filter { $0.id.hasPrefix(g.id + "/") }
                for n in t.inRunOrder(kids, blockedBy: blocked) {
                    let waits = (blocked[n.id] ?? []).map {
                        $0.split(separator: "/").last.map(String.init) ?? $0
                    }
                    let tail = waits.isEmpty
                        ? "\(n.criteriaMet)/\(n.criteriaTotal)"
                        : "after " + waits.joined(separator: ", ")
                    print("  \(n.slug)  \(tail)")
                }
            }
        }

    case "show", "criteria":
        guard let name = args.first else { fail("which node?") }
        let id = try resolve(name)
        guard let n = try store.node(id) else { fail("no such node: \(id)") }
        if wantsJSON {
            if command == "criteria" {
                emit(try store.criteria(of: id).map(json))
            } else {
                var full = n
                full.attachForDisplay(try store.criteria(of: id))
                var out = json(full)
                // The Python counts criteria only when drawing a whole tree,
                // so `show` does not carry the counts. Matching it here rather
                // than being helpfully different.
                for k in ["criteria_met", "criteria_total", "criteria_failed"] {
                    out.removeValue(forKey: k)
                }
                // `show` carries what this node waits on, the same as the
                // Python, including blockers that are already done.
                out["blocked_by"] = try store.db
                    .run("SELECT blocker FROM edges WHERE blocked=?", [s(id)])
                    .compactMap { $0["blocker"]?.string }
                emit(out)
            }
        } else if command == "criteria" {
            for c in try store.criteria(of: id) {
                print("\(c.state == "met" ? "x" : "-") #\(c.id) \(c.text)")
                if let e = c.evidence { print("     evidence: \(e)") }
            }
        } else {
            print("\(n.title)   \(n.state)")
            print("  \(n.id)")
            for c in try store.criteria(of: id) { print("  #\(c.id) \(c.text)  \(c.state)") }
        }

    case "meet", "fail":
        guard let raw = args.first, let cid = Int(raw) else {
            fail("which criterion? give its number")
        }
        let r = try store.set(criterion: cid, to: command == "meet" ? "met" : "failed",
                              actor: actor, evidence: evidence)
        if wantsJSON {
            emit(["criterion": r.criterion, "node": r.node, "state": r.state,
                  "node_closable": r.nodeClosable])
        } else {
            print("#\(r.criterion) on \(r.node) -> \(r.state)"
                  + (r.nodeClosable && r.state == "met"
                     ? "  all criteria met, this node can now be closed" : ""))
        }

    case "state":
        guard args.count >= 2 else { fail("which node, and which state?") }
        let id = try resolve(args[0])
        let n = try store.append(event: id, to: args[1], actor: actor, note: note)
        if wantsJSON { emit(json(n)) } else { print("\(id) -> \(n.state)") }

    case "log":
        let limit = args.first.flatMap(Int.init)
        let rows = try store.db.run("SELECT * FROM events ORDER BY seq")
        let shown = limit.map { Array(rows.suffix($0)) } ?? rows
        if wantsJSON {
            emit(shown.map { r in
                r.mapValues { v -> Any in
                    switch v {
                    case .text(let s): return s
                    case .int(let n): return Int(n)
                    case .null: return NSNull()
                    }
                }
            })
        } else {
            for r in shown {
                print([r["ts"]?.string ?? "", r["actor"]?.string ?? "",
                       r["node"]?.string ?? "",
                       "\(r["from_state"]?.string ?? "") -> \(r["to_state"]?.string ?? "")",
                       r["note"]?.string ?? ""].joined(separator: "  "))
            }
        }

    case "where":
        print(store.db.path)

    default:
        fail("""
            not ported yet: \(command)
            the Swift core covers tree, show, criteria, meet, fail, state, log, where.
            for everything else use ./bin/substrate
            """)
    }
} catch {
    fail("\(error)")
}
