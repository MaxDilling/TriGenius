import SwiftUI

/// Equal columns that cells fill in order, each taking its `Span` of them and
/// wrapping once it no longer fits the line. A line is as tall as its tallest cell,
/// and every cell of it is offered that height.
struct SpanGrid: Layout {
    let columns: Int
    let spacing: CGFloat

    struct Span: LayoutValueKey { static let defaultValue = 1 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        return CGSize(width: width, height: frames(width: width, subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        let unit = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var frames: [CGRect] = []
        var column = 0, lineStart = 0, y: CGFloat = 0
        func closeLine() {
            let height = frames[lineStart...].map(\.height).max() ?? 0
            for i in lineStart..<frames.count { frames[i].size.height = height }
            y += height + spacing
            column = 0
            lineStart = frames.count
        }
        for subview in subviews {
            let span = min(subview[Span.self], columns)
            if column + span > columns { closeLine() }
            let cellWidth = unit * CGFloat(span) + spacing * CGFloat(span - 1)
            let height = subview.sizeThatFits(ProposedViewSize(width: cellWidth, height: nil)).height
            frames.append(CGRect(x: CGFloat(column) * (unit + spacing), y: y, width: cellWidth, height: height))
            column += span
        }
        closeLine()
        return frames
    }
}
