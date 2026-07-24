import Cocoa

enum SplitLayoutManager {
    static func distributeEvenly(in splitView: NSSplitView) {
        let count = splitView.arrangedSubviews.count
        guard count > 1 else { return }

        for index in 0..<count {
            splitView.setHoldingPriority(.defaultLow, forSubviewAt: index)
        }

        splitView.layoutSubtreeIfNeeded()

        let totalSize = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let sizePerPane = totalSize / CGFloat(count)

        for index in 0..<(count - 1) {
            splitView.setPosition(sizePerPane * CGFloat(index + 1), ofDividerAt: index)
        }

        splitView.layoutSubtreeIfNeeded()
    }

    static func setEvenSplit(in splitView: NSSplitView) {
        splitView.layoutSubtreeIfNeeded()
        let totalSize = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        splitView.setPosition(totalSize / 2.0, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
    }
}
