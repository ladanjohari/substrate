import SwiftUI

/// Miller columns: every choice opens the next column, and the detail of the
/// deepest choice sits in the last one.
///
/// What it gives: any depth without indentation eating the width, and the path
/// you took stays on screen. What it takes: every branch except the one you
/// are in. That is the trade, and it is why the picker exists.
struct MillerLayout: View {
    @ObservedObject var model: TreeModel

    private static let columnWidth: CGFloat = 268
    private static let detailWidth: CGFloat = 330

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    ForEach(Array(model.columns.enumerated()), id: \.offset) { depth, rows in
                        column(rows, depth: depth)
                            .frame(width: Self.columnWidth)
                            .id(depth)
                        Divider()
                    }
                    if let node = model.selected {
                        DetailPane(model: model, node: node)
                            .frame(width: Self.detailWidth)
                            .id("detail")
                    } else {
                        NothingSelected().frame(width: Self.detailWidth)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            // Drilling in should not leave the new column off the right edge.
            .onChange(of: model.path) { _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    scroller.scrollTo("detail", anchor: .trailing)
                }
            }
        }
    }

    private func column(_ rows: [TreeNode], depth: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(rows) { n in
                    NodeRow(model: model, node: n,
                            selected: model.chosen(atDepth: depth) == n.id)
                        .onTapGesture { model.select(n.id, atDepth: depth) }
                }
            }
            .padding(.horizontal, 5).padding(.vertical, 6)
        }
    }
}
