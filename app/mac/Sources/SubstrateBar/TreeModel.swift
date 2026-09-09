import Combine
import Foundation

/// The whole plan, and where you are in it.
///
/// This is deliberately separate from how it gets drawn. A layout reads this
/// and writes selection back into it, and nothing else. Adding a layout means
/// adding a view, never touching what a node is or how the tree is fetched,
/// and switching layout keeps your place because the place lives here.
struct TreeNode: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let intent: String
    let exit_criterion: String
    let state: String
    let owner: String?
    let parent: String?
    let criteria_met: Int
    let criteria_total: Int
    var criteria: [Criterion] = []

    struct Criterion: Decodable, Identifiable, Equatable {
        let id: Int
        let text: String
        let state: String
        let evidence: String?
        let checked_by: String?
    }

    /// The short name, which is what a column shows. The full id is a path.
    var slug: String { id.split(separator: "/").last.map(String.init) ?? id }
    var isGoal: Bool { parent == nil }
}

struct TreeEdge: Decodable, Equatable {
    let blocker: String
    let blocked: String
}

struct Tree: Decodable, Equatable {
    var nodes: [TreeNode] = []
    var edges: [TreeEdge] = []
}

@MainActor
final class TreeModel: ObservableObject {
    @Published private(set) var tree = Tree()
    @Published private(set) var offline = false

    /// The path you have drilled into, one id per level. Columns read it left
    /// to right; an outline reads it as the selected row and its ancestors.
    @Published var path: [String] = []

    private let url: URL
    private var timer: Timer?
    private var byId: [String: TreeNode] = [:]
    private var kids: [String: [TreeNode]] = [:]
    private var blockedBy: [String: [String]] = [:]

    init(port: Int = 8040) {
        url = URL(string: "http://127.0.0.1:\(port)/tree")!
    }

    func start(every seconds: TimeInterval = 2) {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func poll() {
        var r = URLRequest(url: url)
        r.timeoutInterval = 3
        URLSession.shared.dataTask(with: r) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                guard let data, error == nil,
                      let fresh = try? JSONDecoder().decode(Tree.self, from: data) else {
                    self.offline = true
                    return
                }
                self.offline = false
                if fresh != self.tree { self.load(fresh) }
            }
        }.resume()
    }

    /// Used by the render modes, so a layout can be reviewed with no store.
    func loadDemo(_ t: Tree) { stop(); load(t); offline = false }

    private func load(_ t: Tree) {
        tree = t
        byId = Dictionary(uniqueKeysWithValues: t.nodes.map { ($0.id, $0) })
        kids = Dictionary(grouping: t.nodes.filter { $0.parent != nil },
                          by: { $0.parent! })
        blockedBy = [:]
        for e in t.edges { blockedBy[e.blocked, default: []].append(e.blocker) }
        for (k, v) in kids { kids[k] = inRunOrder(v) }
        // A path into tasks that no longer exist would leave empty columns and
        // a detail pane showing nothing.
        path = Array(path.prefix(while: { byId[$0] != nil }))
        if path.isEmpty, let first = roots.first { path = [first.id] }
    }

    /// Blockers before the things they block, so "after X" always points at a
    /// row above. Sorted by name a plan reads as nonsense, which is the same
    /// reason the panel orders a proposed plan this way.
    private func inRunOrder(_ nodes: [TreeNode]) -> [TreeNode] {
        var left = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var placed = Set<String>(), out: [TreeNode] = []
        while !left.isEmpty {
            var ready = left.values.filter { n in
                (blockedBy[n.id] ?? []).allSatisfy { placed.contains($0) || left[$0] == nil }
            }
            if ready.isEmpty { ready = Array(left.values) }  // a cycle cannot happen
            for n in ready.sorted(by: { $0.id < $1.id }) {
                out.append(n)
                placed.insert(n.id)
                left[n.id] = nil
            }
        }
        return out
    }

    // MARK: - reading the tree

    var roots: [TreeNode] { tree.nodes.filter { $0.parent == nil }.sorted { $0.id < $1.id } }
    func node(_ id: String) -> TreeNode? { byId[id] }
    func children(of id: String) -> [TreeNode] { kids[id] ?? [] }
    func hasChildren(_ id: String) -> Bool { !(kids[id] ?? []).isEmpty }

    /// What this task waits on, by short name, ignoring anything already done.
    func waitingOn(_ id: String) -> [String] {
        (blockedBy[id] ?? [])
            .filter { byId[$0]?.state != "done" }
            .map { $0.split(separator: "/").last.map(String.init) ?? $0 }
    }

    /// The dot vocabulary, decided once here rather than per layout.
    func dot(_ n: TreeNode) -> Dot {
        switch n.state {
        case "working": return .working
        case "waiting": return .needs
        case "error":   return .error
        case "done":    return .done
        default:        return .idle
        }
    }

    /// The node the detail pane should show: the deepest one you selected.
    var selected: TreeNode? { path.last.flatMap { byId[$0] } }

    // MARK: - moving around

    /// Choose `id` at `depth`, dropping anything deeper. Every layout calls
    /// this, which is why they stay in step with each other.
    func select(_ id: String, atDepth depth: Int) {
        var p = Array(path.prefix(depth))
        p.append(id)
        path = p
    }

    /// The rows in each column: the roots, then the children of each choice.
    var columns: [[TreeNode]] {
        var out: [[TreeNode]] = [roots]
        for id in path {
            // A task with no tasks of its own ends the columns. What it holds
            // is detail, and detail has its own pane.
            guard hasChildren(id) else { break }
            out.append(children(of: id))
        }
        return out
    }

    /// Selection is remembered per level so a layout can highlight the row it
    /// came down through, not only the last one.
    func chosen(atDepth depth: Int) -> String? {
        depth < path.count ? path[depth] : nil
    }
}
