import SwiftUI

/// The popover. It answers one question: does anything need me?
///
/// It is not a tree browser. A menu bar panel is 368 points wide, and every
/// shape that forces a tree into that pays for it in truncated task names. The
/// whole tree opens in a window instead.
struct PanelView: View {
    @ObservedObject var store: Store
    var onOpenTree: () -> Void
    var onQuit: () -> Void

    private static let width: CGFloat = 368
    private static let sidePad: CGFloat = 5
    private static let contentPad: CGFloat = 11

    @State private var expanded: Int?
    @State private var evidence: [Int: String] = [:]
    @State private var lastError: String?
    @State private var composing = false
    @State private var sentence = ""
    @State private var goalError: String?
    @FocusState private var goalField: Bool

    private var p: Panel { store.panel }
    private var rows: Int { p.needs_you.count * 3 + p.running.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)

            if store.offline {
                message("The store is not running",
                        "Start it with: python3 store/substrate_store.py serve 8040")
            } else if let bad = p.thinking.first(where: { $0.failed }) {
                didNotPlan(bad)
            } else if let busy = p.thinking.first {
                working(busy)
            } else if p.goals.isEmpty {
                message("Nothing on the go",
                        "Describe something you want done and it becomes a plan you can approve.")
            } else if let waiting = p.proposed.first {
                // A plan waiting for you is the only thing that matters until
                // you answer it, so it takes the whole panel. Only a long plan
                // scrolls: a ScrollView wrapping content that fits adds nothing
                // and cannot be captured for review.
                if waiting.tasks.count > 10 {
                    ScrollView { plan(waiting) }.frame(maxHeight: 440)
                } else {
                    plan(waiting)
                }
            } else if rows > 8 {
                // Only a long list scrolls. A short one lays itself out
                // directly, which is the common case and the one that can be
                // captured for review.
                ScrollView { content }.frame(maxHeight: 420)
            } else {
                content
            }

            if canCompose && showField { composer }

            Divider().opacity(0.5)
            footer
        }
        .frame(width: Self.width)
        .padding(.vertical, 5)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(p.proposed.first?.title ?? p.goals.first?.title ?? "Substrate")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Text(summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Self.contentPad)
        .padding(.top, 6).padding(.bottom, 8)
    }

    /// The one line of state, in the order a person cares about it.
    private var summary: String {
        let c = p.counts
        if p.thinking.contains(where: { $0.failed }) { return "could not plan it" }
        if !p.thinking.isEmpty { return "working it out" }
        if c.needs_you > 0 { return "\(c.needs_you) needs you" }
        if c.running > 0 { return "\(c.running) running" }
        if c.unapproved_goals > 0 { return "not approved yet" }
        if c.done > 0 && c.ready == 0 && c.blocked == 0 { return "done" }
        return "\(c.ready) ready"
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(p.needs_you) { item in question(item) }

            if !p.running.isEmpty {
                group("Running now")
                ForEach(p.running) { item in
                    row(item.title, right: [item.owner, item.elapsed]
                        .compactMap { $0 }.joined(separator: " · "), dot: .working)
                }
            }

            if quietCount > 0 {
                Text(quietLine)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .padding(.horizontal, Self.contentPad).padding(.top, 6)
            }
        }
        .padding(.bottom, 4)
    }

    private var quietCount: Int { p.counts.ready + p.counts.blocked + p.counts.done }

    private var quietLine: String {
        var bits: [String] = []
        if p.counts.ready > 0 { bits.append("\(p.counts.ready) ready") }
        if p.counts.blocked > 0 { bits.append("\(p.counts.blocked) waiting on something") }
        if p.counts.done > 0 { bits.append("\(p.counts.done) done") }
        return bits.joined(separator: ", ")
    }

    // MARK: - starting a goal

    /// A field is only offered when it is the useful thing to do. During the
    /// half minute of thinking, and while a plan is waiting to be approved,
    /// there is exactly one thing to attend to and typing is not it.
    private var canCompose: Bool { p.thinking.isEmpty && p.proposed.isEmpty }

    /// Open when there is nothing else on the go, because then typing a goal
    /// is the only thing the panel is for.
    private var showField: Bool { composing || p.goals.isEmpty }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TextField("What do you want done?", text: $sentence)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                    .focused($goalField)
                    .onSubmit { startGoal() }
                Button("Plan it") { startGoal() }
                    .controlSize(.small)
                    .disabled(sentence.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let e = goalError {
                Text(e).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Self.contentPad).padding(.top, 8).padding(.bottom, 2)
        // With nothing on the go the field is the only thing to do, so put the
        // cursor in it rather than making you click it first.
        .onAppear { if p.goals.isEmpty { goalField = true } }
    }

    private func startGoal() {
        store.newGoal(sentence: sentence) { problem in
            if let problem { goalError = problem } else {
                sentence = ""; composing = false; goalError = nil
            }
        }
    }

    /// The half minute between a sentence and a plan. Saying nothing here
    /// would look like the app had ignored you.
    private func working(_ t: Panel.Thinking) -> some View {
        VStack(spacing: 7) {
            ProgressView().controlSize(.small)
            Text("Working out the plan").font(.system(size: 13, weight: .medium))
            Text(t.sentence).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("One AI call, about half a minute.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14).padding(.vertical, 16)
    }

    /// It failed, so say what it said. The sentence is kept, because retyping
    /// it is a punishment for the model's mistake.
    private func didNotPlan(_ t: Panel.Thinking) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("That did not turn into a plan")
                .font(.system(size: 13, weight: .semibold))
            Text(t.error ?? "The decomposer gave no reason.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Leave it") { store.forget(thinking: t.id) }.controlSize(.small)
                Button("Try again") {
                    sentence = t.sentence
                    composing = true
                    store.forget(thinking: t.id)
                }
                .controlSize(.small).keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Dot.error.color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Dot.error.color.opacity(0.4), lineWidth: 0.5))
        .padding(.horizontal, Self.sidePad).padding(.vertical, 5)
    }

    /// The plan, before anything has run. Read it, then release it.
    private func plan(_ g: Panel.Proposed) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Nothing runs until you approve this.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, Self.contentPad).padding(.bottom, 8)

            ForEach(g.tasks) { t in
                // What the task is called gets the line to itself. Sharing it
                // with the list of things the task waits on truncated the
                // names, and a plan whose tasks read "Book the..." is not a
                // plan anyone can approve.
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(t.title).font(.system(size: 13)).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text("\(t.total) check\(t.total == 1 ? "" : "s")")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                    if let after = t.after, !after.isEmpty {
                        Text("after " + after.joined(separator: ", "))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .padding(.horizontal, Self.contentPad).padding(.vertical, 4)
            }

            if let e = lastError {
                Text(e).font(.system(size: 11)).foregroundStyle(.red)
                    .padding(.horizontal, Self.contentPad).padding(.top, 6)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Reshape it") { onOpenTree() }.controlSize(.small)
                Button("Approve") { approve(g) }
                    .controlSize(.small).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Self.contentPad).padding(.top, 10)
        }
        .padding(.vertical, 6)
    }

    private func approve(_ g: Panel.Proposed) {
        store.approve(goal: g.id) { problem in lastError = problem }
    }

    /// A task that stopped and needs a person, with the checks it could not
    /// prove. Each one can be closed here, with the evidence that closes it.
    private func question(_ item: Panel.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                DotView(dot: .needs)
                Text(item.title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Dot.needs.color)
                Spacer()
                Text("\(item.met) of \(item.total)")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Dot.needs.color.opacity(0.9))
            }

            let texts = item.open_criteria ?? []
            let ids = item.open_ids ?? []
            ForEach(Array(texts.enumerated()), id: \.offset) { i, text in
                check(id: i < ids.count ? ids[i] : nil, text: text)
            }

            if let e = lastError {
                // The store explains its refusals in words. Show its words.
                Text(e).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if (item.open_criteria ?? []).isEmpty {
                Button("Close this task") { close(item) }
                    .font(.system(size: 12)).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Dot.needs.color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Dot.needs.color.opacity(0.4), lineWidth: 0.5))
        .padding(.horizontal, Self.sidePad).padding(.vertical, 5)
    }

    /// One open check: what it says, and what would show it is true.
    private func check(id: Int?, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 7) {
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(.secondary, lineWidth: 1)
                    .frame(width: 10, height: 10).padding(.top, 2)
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let id, expanded == id {
                HStack(spacing: 6) {
                    TextField("what shows it is true", text: binding(for: id))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .onSubmit { meet(id) }
                    Button("Met") { meet(id) }
                        .font(.system(size: 12)).controlSize(.small)
                        .disabled(evidence[id, default: ""]
                            .trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.leading, 17)
            } else if let id {
                Button("I did this") { expanded = id }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.accentColor)
                    .padding(.leading, 17)
            }
        }
    }

    private func binding(for id: Int) -> Binding<String> {
        Binding(get: { evidence[id, default: ""] }, set: { evidence[id] = $0 })
    }

    private func meet(_ id: Int) {
        let text = evidence[id, default: ""]
        store.meet(criterion: id, evidence: text) { problem in
            if let problem { lastError = problem } else {
                evidence[id] = nil; expanded = nil; lastError = nil
            }
        }
    }

    private func close(_ item: Panel.Item) {
        store.markDone(node: item.id) { problem in lastError = problem }
    }

    private func group(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold)).kerning(0.6)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, Self.contentPad).padding(.top, 8).padding(.bottom, 3)
    }

    private func row(_ title: String, right: String, dot: Dot) -> some View {
        HStack(spacing: 8) {
            DotView(dot: dot)
            Text(title).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            Text(right).font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.secondary).fixedSize()
        }
        .padding(.horizontal, 6).frame(height: 28)
        .padding(.horizontal, Self.sidePad)
    }

    private func message(_ title: String, _ body: String) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(body).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 14).padding(.vertical, 18)
    }

    private var footer: some View {
        HStack(spacing: 13) {
            if canCompose && !showField {
                action("New goal", tint: Color.accentColor) {
                    composing = true
                    goalField = true
                }
            }
            action("Open the full tree", tint: Color.secondary, run: onOpenTree)
            Spacer()
            action("Quit", tint: Color.secondary, run: onQuit)
        }
        .padding(.horizontal, Self.contentPad).padding(.top, 7).padding(.bottom, 2)
    }

    private func action(_ title: String, tint: Color,
                        run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}
