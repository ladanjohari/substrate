import Foundation

/// Starts the store if it is not already running.
///
/// A menu bar app that needs you to open a Terminal and run a Python server
/// first is not a Mac app, it is a Python server with an icon. If nothing
/// answers on the port, start one and keep it as a child, so quitting the app
/// takes it away again.
@MainActor
final class StoreProcess {
    private var child: Process?
    private var signals: [DispatchSourceSignal] = []

    /// Walks up from the running binary to the repo, looking for the store.
    ///
    /// Nonisolated because Record asks for it while working out which file to
    /// open, which happens before anything is on screen.
    ///
    /// Inside an app bundle that walk ends at the bundle, so the build leaves
    /// a marker naming where the repo is and this reads that first.
    nonisolated static func find() -> URL? {
        if let marker = Bundle.main.url(forResource: "repo-path", withExtension: nil),
           let text = try? String(contentsOf: marker, encoding: .utf8) {
            let repo = URL(fileURLWithPath:
                text.trimmingCharacters(in: .whitespacesAndNewlines))
            let store = repo.appendingPathComponent("store/substrate_store.py")
            if FileManager.default.fileExists(atPath: store.path) { return store }
        }
        var dir = (Bundle.main.executableURL
                   ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath().deletingLastPathComponent()
        var looked: [String] = []
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("store/substrate_store.py")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            looked.append(candidate.path)
            if dir.path == "/" { break }
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
        lastLookedIn = looked
        return nil
    }

    /// Where `find` looked and came up empty, so the panel can say something
    /// better than "the store is not running". Moving the repo after building
    /// the app puts you here, and the old message sent you to a directory
    /// that no longer exists.
    nonisolated(unsafe) static var lastLookedIn: [String] = []

    /// nil when the store can be found. Otherwise, what to say about it.
    static func locationProblem() -> String? {
        if find() != nil { return nil }
        let marker = Bundle.main.url(forResource: "repo-path", withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let marker {
            return "This app was built against \(marker), and there is no store there now."
        }
        return "Looked in: " + lastLookedIn.prefix(2).joined(separator: ", ")
    }

    func startIfNeeded(port: Int = 8040) {
        guard child == nil, let script = Self.find() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script.path, "serve", String(port)]
        p.currentDirectoryURL = script.deletingLastPathComponent().deletingLastPathComponent()
        // Say which record, rather than letting the child inherit whatever the
        // app happened to be launched with. Choosing a different one in the
        // panel has to reach the store, or the app and its store would be
        // looking at two different files.
        var env = ProcessInfo.processInfo.environment
        env["SUBSTRATE_DB"] = Record.path
        p.environment = env
        // The store's own output would otherwise land in whatever launched the
        // app, which for a double-click is nowhere useful.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            child = p
            watchForTermination()
            print("started the store from \(script.path)")
        } catch {
            print("could not start the store: \(error.localizedDescription)")
        }
    }

    /// Quitting through the menu calls applicationWillTerminate, but being
    /// killed from a terminal does not, and a store left listening on the port
    /// then blocks the next launch. Catch the signals too.
    private func watchForTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.stopIfOurs()
                exit(0)
            }
            src.resume()
            signals.append(src)
        }
    }

    /// True when the store on the port is the one this app started.
    var isOurs: Bool { child != nil }

    /// Only stops what this app started. A store someone else is running, in a
    /// window they can see, is not ours to kill.
    func stopIfOurs() {
        child?.terminate()
        child = nil
    }
}
