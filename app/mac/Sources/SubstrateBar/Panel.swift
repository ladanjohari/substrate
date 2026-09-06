import Combine
import Foundation

/// What the store hands back from GET /panel.
///
/// The app deliberately does not fetch the whole tree and work out what matters
/// for itself. That judgement lives in the store, so the command line and this
/// app can never disagree about what needs a person.
struct Panel: Decodable, Equatable {
    var goals: [Goal] = []
    var needs_you: [Item] = []
    var running: [Item] = []
    var proposed: [Proposed] = []
    var thinking: [Thinking] = []
    var counts: Counts = Counts()
    var pill: Pill = Pill()

    struct Goal: Decodable, Equatable, Identifiable {
        let id: String
        let title: String
        let state: String
    }

    struct Item: Decodable, Equatable, Identifiable {
        let id: String
        let title: String
        let goal: String
        let state: String
        let owner: String?
        let met: Int
        let total: Int
        let depth: Int
        var open_criteria: [String]?
        var open_ids: [Int]?
        var elapsed: String?
        var after: [String]?
    }

    /// A goal nobody has approved yet, with the plan you are being asked to
    /// approve. The tasks come with it because approving without seeing what
    /// you are approving is the thing this gate exists to prevent.
    struct Proposed: Decodable, Equatable, Identifiable {
        let id: String
        let title: String
        let tasks: [Item]
    }

    /// A sentence that has been typed but is not a plan yet. One AI call
    /// stands between the two and takes about half a minute, so the wait is
    /// something the panel shows rather than something it hides.
    struct Thinking: Decodable, Equatable, Identifiable {
        let id: String
        let sentence: String
        let state: String
        let error: String?
        var failed: Bool { state == "failed" }
    }

    struct Counts: Decodable, Equatable {
        var needs_you = 0, running = 0, ready = 0
        var done = 0, blocked = 0, unapproved_goals = 0
    }

    struct Pill: Decodable, Equatable {
        var dots: [String] = ["hollow"]
        var overflow = 0
    }
}

/// Polls the store and publishes the latest panel.
///
/// A failed poll leaves the last good panel on screen and raises `offline`. A
/// panel that empties itself the moment the store hiccups would teach you to
/// distrust it, which is the opposite of what an indicator is for.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var panel = Panel()
    @Published private(set) var offline = false

    private let url: URL
    private var timer: Timer?

    init(port: Int = 8040) {
        url = URL(string: "http://127.0.0.1:\(port)/panel")!
    }

    func start(every seconds: TimeInterval = 1) {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func poll() {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                guard let data, error == nil,
                      let fresh = try? JSONDecoder().decode(Panel.self, from: data) else {
                    self.offline = true
                    return
                }
                self.offline = false
                if fresh != self.panel { self.panel = fresh }
            }
        }.resume()
    }

    /// Only used by the render modes, so the design can be reviewed without a
    /// store running.
    func loadDemo(_ p: Panel) { stop(); panel = p; offline = false }

    // MARK: - writing back

    /// Mark one check met, with the evidence that shows it.
    ///
    /// The store refuses this without evidence, which is the rule the whole
    /// thing rests on, so the panel refuses too rather than sending a request
    /// it knows will bounce.
    func meet(criterion: Int, evidence: String, then: @escaping (String?) -> Void) {
        let text = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return then("Say what shows it is true.") }
        post("/criterion/set",
             ["criterion": criterion, "to": "met", "evidence": text, "actor": "you"], then)
    }

    /// Release a plan to the agents. Until this, nothing runs.
    ///
    /// The store will only accept it on a goal that is waiting, so a second
    /// press cannot start anything twice.
    func approve(goal: String, then: @escaping (String?) -> Void) {
        post("/approve", ["goal": goal, "actor": "you",
                          "note": "approved from the menu bar"], then)
    }

    /// Turn a sentence into a proposed plan.
    ///
    /// This returns as soon as the store has taken the sentence, not when the
    /// plan exists. The wait then arrives on the next poll, as `thinking`, so
    /// one slow AI call cannot freeze the panel.
    func newGoal(sentence: String, then: @escaping (String?) -> Void) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return then("Say what you want done.") }
        post("/goal/new", ["sentence": text, "actor": "you"], then)
    }

    /// Drop a failed attempt once you have read why it failed.
    func forget(thinking id: String) {
        post("/goal/forget", ["id": id, "actor": "you"]) { _ in }
    }

    /// Close a task. The store refuses while any check is still open.
    func markDone(node: String, then: @escaping (String?) -> Void) {
        post("/event", ["node": node, "to": "done", "actor": "you",
                        "note": "closed from the menu bar"], then)
    }

    private func post(_ path: String, _ body: [String: Any],
                      _ then: @escaping (String?) -> Void) {
        var r = URLRequest(url: url.deletingLastPathComponent()
            .appendingPathComponent(String(path.dropFirst())))
        r.httpMethod = "POST"
        r.timeoutInterval = 5
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: r) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { return then(error.localizedDescription) }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code >= 400 {
                    // The store explains its refusals in words; show its words,
                    // not a status code.
                    let why = (try? JSONSerialization.jsonObject(with: data ?? Data()))
                        .flatMap { ($0 as? [String: Any])?["error"] as? String }
                    return then(why ?? "the store refused that")
                }
                self.poll()
                then(nil)
            }
        }.resume()
    }
}
