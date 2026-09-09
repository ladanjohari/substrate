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
    static func find() -> URL? {
        var dir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("store/substrate_store.py")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    func startIfNeeded(port: Int = 8040) {
        guard child == nil, let script = Self.find() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script.path, "serve", String(port)]
        p.currentDirectoryURL = script.deletingLastPathComponent().deletingLastPathComponent()
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

    /// Only stops what this app started. A store someone else is running, in a
    /// window they can see, is not ours to kill.
    func stopIfOurs() {
        child?.terminate()
        child = nil
    }
}
