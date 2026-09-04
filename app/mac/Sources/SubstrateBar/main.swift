import AppKit
import Combine
import SwiftUI

/// Mock data for the render modes, so the design can be reviewed without the
/// store running and without waiting for real agents to reach an interesting
/// state. Taken from a real run, not invented.
@MainActor
func demoPanel() -> Panel {
    var p = Panel()
    p.goals = [.init(id: "resume", title: "Write my resume", state: "working")]
    p.needs_you = [.init(id: "resume/exp/roles", title: "List the roles", goal: "resume",
                         state: "waiting", owner: nil, met: 0, total: 2, depth: 1,
                         open_criteria: ["Every role is listed with company, title and dates",
                                         "No claim the source notes do not support"],
                         open_ids: [4, 5], elapsed: nil)]
    p.running = [.init(id: "resume/exp/bullets", title: "Draft each bullet", goal: "resume",
                       state: "working", owner: "agent 1", met: 1, total: 3, depth: 1,
                       open_criteria: nil, open_ids: nil, elapsed: "2m"),
                 .init(id: "resume/education", title: "Write the education section",
                       goal: "resume", state: "working", owner: "agent 2", met: 0, total: 3,
                       depth: 0, open_criteria: nil, open_ids: nil, elapsed: "1m")]
    p.counts = .init(needs_you: 1, running: 2, ready: 1, done: 2, blocked: 2,
                     unapproved_goals: 0)
    p.pill = .init(dots: ["needs", "working", "working", "done"], overflow: 3)
    return p
}

/// `--render-pill out.png` and `--render-panel out.png` draw the interface on
/// its own at high magnification. A menu bar item is 22 points tall, which is
/// too small to review on a screenshot, and squinting is not a design process.
@MainActor
func render(_ view: some View, to path: String, scale: CGFloat, dark: Bool) {
    Motion.still = true
    let renderer = ImageRenderer(
        content: view.padding(10)
            .background(dark ? Color(white: 0.13) : Color(white: 0.93))
            .environment(\.colorScheme, dark ? .dark : .light))
    renderer.scale = scale
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    } else {
        print("could not render \(path)")
    }
}

let args = CommandLine.arguments

if let i = args.firstIndex(of: "--render-pill"), i + 1 < args.count {
    MainActor.assumeIsolated {
        let store = Store(); store.loadDemo(demoPanel())
        render(PillView(store: store), to: args[i + 1], scale: 8,
               dark: args.contains("--dark"))
    }
    exit(0)
}

if let i = args.firstIndex(of: "--render-panel"), i + 1 < args.count {
    MainActor.assumeIsolated {
        let store = Store()
        store.loadDemo(args.contains("--empty") ? Panel() : demoPanel())
        render(PanelView(store: store, onOpenTree: {}, onQuit: {}),
               to: args[i + 1], scale: 2, dark: args.contains("--dark"))
    }
    exit(0)
}

/// `--print` polls the store once and prints what it sees, so the connection
/// can be checked without the interface.
if args.contains("--print") {
    let store = MainActor.assumeIsolated { Store() }
    MainActor.assumeIsolated { store.poll() }
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let done = MainActor.assumeIsolated { store.offline || !store.panel.goals.isEmpty }
        if done { break }
    }
    MainActor.assumeIsolated {
        if store.offline {
            print("store not reachable on 127.0.0.1:8040")
        } else {
            let p = store.panel
            print("pill: \(p.pill.dots.joined(separator: " ")) +\(p.pill.overflow)")
            for i in p.needs_you { print("needs you: \(i.title)  \(i.met)/\(i.total)") }
            for i in p.running {
                print("running:   \(i.title)  \(i.owner ?? "?")  \(i.elapsed ?? "")")
            }
        }
    }
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let store = Store()
    private let storeProcess = StoreProcess()
    private let popover = NSPopover()
    private var pill: NSHostingView<PillView>!
    private var outsideClick: Any?
    private var sizeObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        pill = NSHostingView(rootView: PillView(store: store))
        pill.translatesAutoresizingMaskIntoConstraints = false

        if let button = statusItem.button {
            // The pill draws its own capsule. Left alone the status item draws a
            // second one on mouse down, wider than the first, so clicking looked
            // like the pill growing.
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                pill.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            ])
            button.target = self
            button.action = #selector(toggle)
        }

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PanelView(store: store,
                                onOpenTree: { [weak self] in self?.openTree() },
                                onQuit: { NSApp.terminate(nil) }))

        // The status item is told how wide to be every time the pill changes.
        sizeObserver = store.$panel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.fit() }
        fit()
        store.start()

        // If nothing answers on the port after a moment, start the store
        // ourselves rather than sitting there offline.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.store.offline else { return }
            self.storeProcess.startIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        storeProcess.stopIfOurs()
    }

    private func fit() {
        pill.layoutSubtreeIfNeeded()
        let w = pill.fittingSize.width
        if w > 0 { statusItem.length = w + 6 }
    }

    private func openTree() {
        // Until the window exists, the browser pages are the full tree. They
        // are served by a second little server, so start that too rather than
        // opening an address nothing is listening on.
        storeProcess.startPagesIfNeeded()
        let url = URL(string: "http://localhost:8004/prototypes/live-tree/live-tree.html")!
        // Give it a moment to bind the port, or the browser lands on an error.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSWorkspace.shared.open(url)
        }
        close()
    }

    @objc private func toggle() {
        popover.isShown ? close() : show()
    }

    private func show() {
        guard let button = statusItem.button else { return }
        store.poll()
        // Without this the panel is placed as though it belonged to whatever
        // app is in front, and lands well below the menu bar.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
        outsideClick = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
    }

    private func close() {
        if let m = outsideClick { NSEvent.removeMonitor(m); outsideClick = nil }
        popover.performClose(nil)
    }

    func applicationDidResignActive(_ notification: Notification) {
        if popover.isShown { close() }
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
// Menu bar only, no Dock icon. `--preview` runs it as an ordinary app instead,
// which is the only way to capture the popover on screen while designing it.
app.setActivationPolicy(args.contains("--preview") ? .regular : .accessory)
app.run()
