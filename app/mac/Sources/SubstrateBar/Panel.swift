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
        var elapsed: String?
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
}
