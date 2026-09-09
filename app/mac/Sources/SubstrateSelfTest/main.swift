import Foundation
import SubstrateCore

// The two rules are the product, so they are the thing with tests.
//
// Not XCTest: that framework needs full Xcode, and this has to run for anyone
// with the command line tools, which is what `swift build` needs anyway. So it
// is an ordinary command that prints what it checked and exits nonzero if any
// of it is wrong.
//
//     swift build && .build/debug/substrate-selftest

var failures: [String] = []
var checked = 0

func check(_ what: String, _ ok: @autoclosure () throws -> Bool) {
    checked += 1
    do {
        if try ok() { print("  ok    \(what)") }
        else { print("  FAIL  \(what)"); failures.append(what) }
    } catch {
        print("  FAIL  \(what)  (threw: \(error))")
        failures.append(what)
    }
}

/// Runs the body and hands back the refusal message, or nil if it was allowed.
func refusal(_ body: () throws -> Void) -> String? {
    do { try body(); return nil } catch { return "\(error)" }
}

let path = NSTemporaryDirectory() + "substrate-selftest-\(UUID().uuidString).db"
defer { try? FileManager.default.removeItem(atPath: path) }
let store = try Substrate(path: path)

try store.db.run("""
    INSERT INTO nodes (id,title,intent,exit_criterion,state) VALUES
    ('g','A goal','why','done when done','idle')
    """)
try store.db.run("""
    INSERT INTO nodes (id,title,intent,exit_criterion,parent) VALUES
    ('g/t','A task','why','done when done','g')
    """)
try store.db.run("INSERT INTO criteria (node, ord, text) VALUES ('g/t',0,'First thing')")
try store.db.run("INSERT INTO criteria (node, ord, text) VALUES ('g/t',1,'Second thing')")

print("\nRule one: nothing is done while a criterion is open")
let openRefusal = refusal { _ = try store.append(event: "g/t", to: "done", actor: "test") }
check("done is refused", openRefusal != nil)
check("it says how many are open", openRefusal?.contains("2 criteria still open") == true)
check("it names every open criterion",
      openRefusal?.contains("First thing") == true && openRefusal?.contains("Second thing") == true)
check("a refused move changes nothing", try store.node("g/t")?.state == "idle")

print("\nRule two: nothing is met without evidence")
let cs = try store.criteria(of: "g/t")
check("met with no evidence is refused",
      refusal { _ = try store.set(criterion: cs[0].id, to: "met", actor: "test") } != nil)
check("met with empty evidence is refused",
      refusal { _ = try store.set(criterion: cs[0].id, to: "met", actor: "test", evidence: "") } != nil)
check("the criterion is untouched by the refusal", try store.criteria(of: "g/t")[0].state == "unmet")
check("failing needs no evidence, because it claims nothing",
      try store.set(criterion: cs[0].id, to: "failed", actor: "test").state == "failed")

print("\nThe two rules together")
for c in try store.criteria(of: "g/t") {
    _ = try store.set(criterion: c.id, to: "met", actor: "test", evidence: "it happened")
}
check("done is allowed once every criterion is met",
      try store.append(event: "g/t", to: "done", actor: "test").state == "done")
check("a node with no criteria cannot be closed", try {
    try store.db.run("""
        INSERT INTO nodes (id,title,intent,exit_criterion,parent) VALUES
        ('g/bare','No checks','why','none','g')
        """)
    return refusal { _ = try store.append(event: "g/bare", to: "done", actor: "test") }?
        .contains("no exit criteria") == true
}())

print("\nThe record")
check("evidence is written into the log", try {
    let events = try store.db.run("SELECT * FROM events WHERE note LIKE '%it happened%'")
    return !events.isEmpty
}())
check("leaving working releases the owner", try {
    try store.db.run("UPDATE nodes SET owner='agent 1' WHERE id='g/bare'")
    _ = try store.append(event: "g/bare", to: "waiting", actor: "test")
    return try store.node("g/bare")?.owner == nil
}())
check("working keeps the owner", try {
    try store.db.run("UPDATE nodes SET owner='agent 1' WHERE id='g/bare'")
    _ = try store.append(event: "g/bare", to: "working", actor: "test")
    return try store.node("g/bare")?.owner == "agent 1"
}())
check("an unknown state is refused",
      refusal { _ = try store.append(event: "g/t", to: "finished", actor: "test") } != nil)
check("root goal walks up from any depth", try {
    try store.db.run("""
        INSERT INTO nodes (id,title,intent,exit_criterion,parent) VALUES
        ('g/t/deep','Deeper','why','none','g/t')
        """)
    return try store.rootGoal(of: "g/t/deep") == "g"
        && (try store.rootGoal(of: "g")) == "g"
}())

print("")
if failures.isEmpty {
    print("all \(checked) checks passed")
    exit(0)
}
print("\(failures.count) of \(checked) checks failed")
exit(1)
