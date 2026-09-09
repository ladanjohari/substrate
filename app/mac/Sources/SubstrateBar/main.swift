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
    return p
}

/// The other state worth reviewing: a plan nobody has approved.
@MainActor
func demoPlan() -> Panel {
    var p = Panel()
    p.goals = [.init(id: "resume", title: "Write my resume", state: "waiting")]
    func t(_ id: String, _ title: String, _ n: Int, _ after: [String] = []) -> Panel.Item {
        .init(id: "resume/" + id, title: title, goal: "resume", state: "idle", owner: nil,
              met: 0, total: n, depth: 0, open_criteria: nil, open_ids: nil,
              elapsed: nil, after: after)
    }
    p.proposed = [.init(id: "resume", title: "Write my resume", tasks: [
        t("format", "Choose a format", 2),
        t("gather", "Gather career information", 3),
        t("exp", "Write the experience section", 3, ["format", "gather"]),
        t("edu", "Write the education section", 3, ["format", "gather"]),
        t("proof", "Edit and proofread", 2, ["exp", "edu"]),
        t("export", "Export and save", 2, ["proof"]),
    ])]
    p.counts = .init(needs_you: 0, running: 0, ready: 0, done: 0, blocked: 6,
                     unapproved_goals: 1)
    p.pill = .init(dots: ["idle"], overflow: 0)
    p.pill = .init(dots: ["needs", "working", "working", "done"], overflow: 3)
    return p
}

/// The half minute between typing a goal and having a plan, and the state
/// where that half minute produced nothing.
@MainActor
func demoThinking(failed: Bool) -> Panel {
    // Built on top of a busy panel on purpose: the card must sit above real
    // work rather than hiding it, which is what it used to do.
    var p = demoPanel()
    p.thinking = [.init(id: "1", sentence: "Write my resume",
                        state: failed ? "failed" : "thinking",
                        error: failed ? "the claude command could not run: Failed to authenticate. If it says authenticate: open a terminal, run `claude`, log in, try again" : nil)]
    p.pill = .init(dots: failed ? ["needs", "error"] : ["needs", "working"], overflow: 1)
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
        store.loadDemo(args.contains("--empty") ? Panel()
                       : args.contains("--thinking") ? demoThinking(failed: false)
                       : args.contains("--failed") ? demoThinking(failed: true)
                       : args.contains("--plan") ? demoPlan() : demoPanel())
        render(PanelView(store: store, onOpenTree: {}, onQuit: {}),
               to: args[i + 1], scale: 2, dark: args.contains("--dark"))
    }
    exit(0)
}

/// `--login on|off|status` checks that opening at login actually works, from
/// a terminal, without hunting for the switch in the panel.
if let i = args.firstIndex(of: "--login") {
    let want = i + 1 < args.count ? args[i + 1] : "status"
    MainActor.assumeIsolated {
        guard LoginItem.available else {
            print("not a bundled app, so macOS has nothing to register.")
            print("build it first:  ./make-app.sh")
            exit(1)
        }
        if want == "status" {
            print(LoginItem.on ? "opens at login" : "does not open at login")
        } else if let problem = LoginItem.set(want == "on") {
            print("macOS refused: \(problem)")
            exit(1)
        } else {
            print(LoginItem.on ? "opens at login" : "does not open at login")
        }
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
    private var previewWindow: NSWindow?
    private var treeWindow: NSWindow?
    private let treeModel = TreeModel()
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
                // Without this the hosting view's own height grows the button,
                // and everything positioned against the button goes with it.
                pill.heightAnchor.constraint(
                    equalToConstant: NSStatusBar.system.thickness),
            ])
            button.target = self
            button.action = #selector(toggle)
        }

        popover.behavior = .transient
        popover.delegate = self
        let panel = NSHostingController(
            rootView: PanelView(store: store,
                                onOpenTree: { [weak self] in self?.openTree() },
                                onQuit: { NSApp.terminate(nil) }))
        // Tell the popover how big the panel wants to be.
        //
        // Without this the popover opens at some default size, then the
        // SwiftUI content settles to its real height and the window shrinks
        // from the top, leaving the panel hanging about 150 points below the
        // menu bar. That is the "opens very low" she reported. Activating the
        // app first fixed where it sat horizontally, not this, and I wrongly
        // called it fixed then.
        panel.sizingOptions = [.preferredContentSize]
        popover.contentViewController = panel

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

        // In preview mode put the same panel in an ordinary window as well.
        // A text field cannot be drawn by ImageRenderer, so the only honest
        // picture of one is a screenshot of the thing actually running, and a
        // popover closes the moment anything else takes focus.
        // `--preview --tree` opens the window straight away, so both layouts
        // can be looked at without hunting for the menu bar item.
        // `--demo` opens the panel straight away and leaves it open, for
        // recording. See applicationDidResignActive.
        if args.contains("--demo") {
            // Activate first, then show. A popover opened while the app is not
            // active is placed as though it belonged to whatever is in front,
            // and lands well below the menu bar.
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.show()
            }
        }

        if args.contains("--tree") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openTree()
            }
        }

        if args.contains("--preview") {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 368, height: 260),
                             styleMask: [.titled, .closable], backing: .buffered,
                             defer: false)
            w.title = "Substrate (preview)"
            w.contentView = NSHostingView(
                rootView: PanelView(store: store, onOpenTree: {},
                                    onQuit: { NSApp.terminate(nil) }))
            w.center()
            w.makeKeyAndOrderFront(nil)
            previewWindow = w
            NSApp.activate(ignoringOtherApps: true)
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
        // The full tree is a window of this app now, not a browser page on a
        // second little server. One window, reused: opening it again brings
        // back the one you had, with the place you were in still selected.
        if treeWindow == nil {
            treeModel.start()
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Substrate"
            w.isReleasedWhenClosed = false
            var forced: TreeLayout?
            if let i = args.firstIndex(of: "--layout"), i + 1 < args.count {
                forced = TreeLayout(rawValue: args[i + 1])
            }
            w.contentView = NSHostingView(
                rootView: TreeWindowView(model: treeModel, forced: forced))
            // `--select` drills straight in, so a capture can show the columns
            // opened up. It calls the same function a click calls.
            if let i = args.firstIndex(of: "--select"), i + 1 < args.count {
                let ids = args[i + 1].split(separator: ",").map(String.init)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    for (depth, id) in ids.enumerated() {
                        self?.treeModel.select(id, atDepth: depth)
                    }
                }
            }
            w.center()
            treeWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        treeWindow?.makeKeyAndOrderFront(nil)
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
        // Anchor to the menu bar, not to the button's bounds.
        //
        // The pill is a hosting view inside the button, and its own height was
        // stretching the button's bounds well past the 24 points a menu bar
        // item occupies. Handing those bounds to the popover put the panel
        // about 150 points too low, hanging in the middle of the screen. I
        // said this was fixed before; activating the app first fixed where it
        // was placed horizontally, not this.
        if args.contains("--why-low") {
            let lines = """
            button.bounds  \(button.bounds)
            button.frame   \(button.frame)
            window.frame   \(String(describing: button.window?.frame))
            statusItem.len \(statusItem.length)
            thickness      \(NSStatusBar.system.thickness)
            screen         \(String(describing: NSScreen.main?.frame))
            visibleFrame   \(String(describing: NSScreen.main?.visibleFrame))
            """
            try? lines.write(toFile: "/tmp/why.txt", atomically: true, encoding: .utf8)
        }
        let bar = NSRect(x: 0, y: 0,
                         width: button.bounds.width,
                         height: NSStatusBar.system.thickness)
        popover.show(relativeTo: bar, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
        outsideClick = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.close() }
            }
    }

    private func close() {
        if args.contains("--demo") { return }
        if let m = outsideClick { NSEvent.removeMonitor(m); outsideClick = nil }
        popover.performClose(nil)
    }

    func applicationDidResignActive(_ notification: Notification) {
        // A detached panel is a window of its own and must not be dismissed
        // just because you clicked another app.
        //
        // `--demo` also keeps it open: a screen recording is driven from
        // outside the app, and a panel that closes the moment something else
        // takes focus cannot be filmed. Nothing else about it changes.
        if args.contains("--demo") { return }
        if popover.isShown && !popover.isDetached { close() }
    }
}

extension AppDelegate: NSPopoverDelegate {
    /// Let the panel be dragged off the menu bar into a real window.
    ///
    /// This is the platform's own answer to the tension in a menu bar app: a
    /// transient popover is right for a glance and wrong for anything that
    /// takes thought, because it vanishes the moment you look at the thing you
    /// are describing. Dragging it off turns the glance into a window, and the
    /// split between looking and working becomes a gesture rather than a rule.
    ///
    /// AppKit builds the window itself from the same content view controller,
    /// which is why there is nothing else to implement here. Apple's own note
    /// says returning true and letting it do that is preferred over supplying
    /// a custom window.
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    func popoverDidDetach(_ popover: NSPopover) {
        // Nothing is watching for outside clicks any more; the window handles
        // its own life now.
        if let m = outsideClick { NSEvent.removeMonitor(m); outsideClick = nil }
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
// Menu bar only, no Dock icon. `--preview` runs it as an ordinary app instead,
// which is the only way to capture the popover on screen while designing it.
app.setActivationPolicy(args.contains("--preview") ? .regular : .accessory)
app.run()
