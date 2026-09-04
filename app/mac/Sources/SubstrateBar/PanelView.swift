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

    private var p: Panel { store.panel }
    private var rows: Int { p.needs_you.count * 3 + p.running.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.5)

            if store.offline {
                message("The store is not running",
                        "Start it with: python3 store/substrate_store.py serve 8040")
            } else if p.goals.isEmpty {
                message("Nothing on the go",
                        "Describe something you want done and it becomes a plan you can approve.")
            } else if rows > 8 {
                // Only a long list scrolls. A short one lays itself out
                // directly, which is the common case and the one that can be
                // captured for review.
                ScrollView { content }.frame(maxHeight: 420)
            } else {
                content
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(width: Self.width)
        .padding(.vertical, 5)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(p.goals.first?.title ?? "Substrate")
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
        if c.needs_you > 0 { return "\(c.needs_you) needs you" }
        if c.running > 0 { return "\(c.running) running" }
        if c.unapproved_goals > 0 { return "waiting for you to approve" }
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
        HStack {
            action("Open the full tree", tint: Color.accentColor, run: onOpenTree)
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
