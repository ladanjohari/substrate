import SwiftUI

/// The window's layouts, and the seam they all sit behind.
///
/// He asked for Miller columns, so that is the default. The point of this file
/// is that changing our minds later, or showing two ways side by side, costs
/// one case and one view. Nothing about the tree, the polling, the detail
/// pane or the dot vocabulary is duplicated per layout, so nobody has to be
/// told how a layout works before adding another.
///
/// To add one:
///   1. add a case here, with a name and a one-line description
///   2. add its view to `draw`
///   3. that is all. It gets the tree, the selection and the detail pane free
enum TreeLayout: String, CaseIterable, Identifiable {
    case miller
    case outline

    var id: String { rawValue }

    /// What it is called in the picker.
    var name: String {
        switch self {
        case .miller:  return "Columns"
        case .outline: return "Outline"
        }
    }

    /// What it gives you, in one line, for anyone deciding between them.
    var note: String {
        switch self {
        case .miller:
            return "Every choice opens the next column. Any depth, and the path you took stays visible."
        case .outline:
            return "One indented list, every branch at once, detail pinned to the right."
        }
    }

    @ViewBuilder func draw(_ model: TreeModel) -> some View {
        switch self {
        case .miller:  MillerLayout(model: model)
        case .outline: OutlineLayout(model: model)
        }
    }
}

/// The window: a picker, the chosen layout, and nothing else.
///
/// The choice is remembered between launches, so opening the tree does not
/// mean choosing a layout again every time.
struct TreeWindowView: View {
    @ObservedObject var model: TreeModel
    /// Set by `--layout` so a capture can show either one without clicking.
    var forced: TreeLayout?
    @AppStorage("treeLayout") private var stored = TreeLayout.miller.rawValue

    private var layout: TreeLayout { forced ?? TreeLayout(rawValue: stored) ?? .miller }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            if model.offline {
                VStack(spacing: 4) {
                    Text("The store is not running").font(.system(size: 13, weight: .medium))
                    Text("Start it with: python3 store/substrate_store.py serve 8040")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.roots.isEmpty {
                VStack(spacing: 4) {
                    Text("Nothing on the go").font(.system(size: 13, weight: .medium))
                    Text("Type a goal in the menu bar and it becomes a plan here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                layout.draw(model)
            }
        }
        .frame(minWidth: 720, minHeight: 420)
    }

    private var bar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $stored) {
                ForEach(TreeLayout.allCases) { l in Text(l.name).tag(l.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)

            Text(layout.note)
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(breadcrumb).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.head)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Where you are, in words. It reads the same whichever layout drew it,
    /// which is the quickest proof that the two share one selection.
    private var breadcrumb: String {
        model.path.compactMap { model.node($0)?.title }.joined(separator: "  ›  ")
    }
}

// MARK: - shared pieces every layout gets

/// One row, drawn the same way everywhere: state, name, and what it is waiting
/// on or how many checks are left.
struct NodeRow: View {
    @ObservedObject var model: TreeModel
    let node: TreeNode
    let selected: Bool
    var showChevron = true

    var body: some View {
        // The name gets the line. What it waits on goes underneath, because a
        // long list of blockers otherwise squeezes the title to nothing, and a
        // row that reads "Bak..." names no task at all.
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                DotView(dot: model.dot(node))
                // Two lines, because a task title is a sentence, not a
                // filename. One line turns "Grow a healthy sourdough starter"
                // into "Grow a healthy sour..." which names nothing.
                Text(node.title).font(.system(size: 13)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if node.criteria_total > 0 {
                    Text("\(node.criteria_met)/\(node.criteria_total)")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.tertiary).fixedSize()
                }
                if showChevron && model.hasChildren(node.id) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            let waits = model.waitingOn(node.id)
            if !waits.isEmpty {
                Text("after " + waits.joined(separator: ", "))
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(selected ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
    }
}

/// What one task actually is: why it exists, what closes it, and every check
/// with its evidence. Shared, so a layout never decides what a task is.
struct DetailPane: View {
    @ObservedObject var model: TreeModel
    let node: TreeNode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    DotView(dot: model.dot(node))
                    Text(node.title).font(.system(size: 15, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(node.id).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary).padding(.top, 3)

                if let owner = node.owner, !owner.isEmpty {
                    label("With", owner)
                }
                if !node.intent.isEmpty {
                    label("Why", node.intent)
                }
                let waits = model.waitingOn(node.id)
                if !waits.isEmpty {
                    label("Waits for", waits.joined(separator: ", "))
                }

                Text("CHECKS  \(node.criteria_met) of \(node.criteria_total) met")
                    .font(.system(size: 10.5, weight: .semibold)).kerning(0.6)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 18).padding(.bottom, 6)

                ForEach(node.criteria) { c in check(c) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func label(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6).foregroundStyle(.tertiary)
            Text(body).font(.system(size: 12.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 16)
    }

    private func check(_ c: TreeNode.Criterion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 7) {
                mark(c.state)
                Text(c.text).font(.system(size: 12.5))
                    .foregroundStyle(c.state == "met" ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let e = c.evidence, !e.isEmpty {
                Text(e).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 18)
            }
        }
        .padding(.bottom, 9)
    }

    @ViewBuilder private func mark(_ state: String) -> some View {
        switch state {
        case "met":
            Image(systemName: "checkmark.square.fill")
                .font(.system(size: 11)).foregroundStyle(Dot.done.color).padding(.top, 1)
        case "failed":
            Image(systemName: "xmark.square.fill")
                .font(.system(size: 11)).foregroundStyle(Dot.error.color).padding(.top, 1)
        default:
            RoundedRectangle(cornerRadius: 2.5).strokeBorder(.tertiary, lineWidth: 1)
                .frame(width: 11, height: 11).padding(.top, 2)
        }
    }
}

/// Shown in place of the detail pane when nothing is selected deeply enough.
struct NothingSelected: View {
    var body: some View {
        Text("Pick a task to see what closes it")
            .font(.system(size: 12)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
