import SwiftUI

/// One indented list, every branch visible at once, with the detail pinned to
/// the right where it does not move as the tree changes underneath it.
///
/// This is the second layout on purpose. One layout behind a picker proves
/// nothing; two that share the same model, the same row and the same detail
/// pane prove the seam holds, and give him something to compare.
struct OutlineLayout: View {
    @ObservedObject var model: TreeModel
    @State private var collapsed: Set<String> = []

    private static let detailWidth: CGFloat = 330

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visible, id: \.node.id) { row in
                        HStack(spacing: 0) {
                            twist(row.node)
                            NodeRow(model: model, node: row.node,
                                    selected: model.path.last == row.node.id,
                                    showChevron: false)
                        }
                        .padding(.leading, CGFloat(row.depth) * 15)
                        .onTapGesture { model.select(row.node.id, atDepth: row.depth) }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            if let node = model.selected {
                DetailPane(model: model, node: node).frame(width: Self.detailWidth)
            } else {
                NothingSelected().frame(width: Self.detailWidth)
            }
        }
    }

    /// A goal and everything under it, flattened, with anything you folded
    /// away left out.
    private var visible: [(node: TreeNode, depth: Int)] {
        var out: [(TreeNode, Int)] = []
        func walk(_ nodes: [TreeNode], _ depth: Int) {
            for n in nodes {
                out.append((n, depth))
                if !collapsed.contains(n.id) {
                    walk(model.children(of: n.id), depth + 1)
                }
            }
        }
        walk(model.roots, 0)
        return out.map { (node: $0.0, depth: $0.1) }
    }

    @ViewBuilder private func twist(_ n: TreeNode) -> some View {
        if model.hasChildren(n.id) {
            Button {
                if collapsed.contains(n.id) { collapsed.remove(n.id) }
                else { collapsed.insert(n.id) }
            } label: {
                Image(systemName: collapsed.contains(n.id)
                      ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: 14, height: 1)
        }
    }
}
