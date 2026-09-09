import AppKit
import Foundation

/// Which record the app is looking at.
///
/// The same app, the same dots, completely different content depending on one
/// environment variable, and nothing on screen said which. That confused the
/// person who built it, twice, which is a fair test.
///
/// So the record is a thing you choose and the app remembers, the panel says
/// which one you are in, and opening a different one does not require a
/// terminal.
enum Record {
    private static let key = "recordPath"

    /// In order: what the environment says, what you last chose, then the one
    /// next to the code.
    static var path: String {
        if let env = ProcessInfo.processInfo.environment["SUBSTRATE_DB"], !env.isEmpty {
            return (env as NSString).expandingTildeInPath
        }
        if let saved = UserDefaults.standard.string(forKey: key),
           FileManager.default.fileExists(atPath: saved) {
            return saved
        }
        return fallback
    }

    /// The record that sits beside the store, which is what both the command
    /// line and the app mean when nobody has said otherwise.
    static var fallback: String {
        if let store = StoreProcess.find() {
            return store.deletingLastPathComponent()
                .appendingPathComponent("substrate.db").path
        }
        return NSHomeDirectory() + "/substrate.db"
    }

    /// What to call it on screen. The file name is what a person recognises;
    /// the default one is just "your record".
    static var name: String {
        let p = path
        if p == fallback { return "your record" }
        return (p as NSString).lastPathComponent
    }

    /// True when the environment picked it, in which case choosing another
    /// from the panel would be overruled on the next launch and it would look
    /// like the app ignored you.
    static var fixedByEnvironment: Bool {
        !(ProcessInfo.processInfo.environment["SUBSTRATE_DB"] ?? "").isEmpty
    }

    static func remember(_ p: String) {
        UserDefaults.standard.set(p, forKey: key)
    }

    /// Ask for a different one. Returns the chosen path, or nil if cancelled.
    @MainActor static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Open a record"
        panel.message = "A substrate record is a .db file. Pick one, or name a new one."
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        remember(url.path)
        return url.path
    }
}
