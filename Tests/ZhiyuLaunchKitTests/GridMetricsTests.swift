import CoreGraphics
import Testing
@testable import ZhiyuLaunchKit

struct GridMetricsTests {
    @Test func thirteenInchLayoutMatchesClassicLaunchpad() {
        let metrics = GridMetrics.compute(for: CGSize(width: 1440, height: 900))
        #expect(metrics.columns == 7)
        #expect(metrics.rows == 5)
        #expect(metrics.itemsPerPage == 35)
    }

    @Test func largeDisplayClampsToEightBySix() {
        let metrics = GridMetrics.compute(for: CGSize(width: 2560, height: 1440))
        #expect(metrics.columns == 8)
        #expect(metrics.rows == 6)
    }

    @Test func smallDisplayGetsAtLeastFourByThree() {
        let metrics = GridMetrics.compute(for: CGSize(width: 1024, height: 640))
        #expect(metrics.columns >= 4)
        #expect(metrics.rows >= 3)
    }

    @Test func iconSizeStaysWithinReasonableRange() {
        for size in [CGSize(width: 1280, height: 800), CGSize(width: 1440, height: 900), CGSize(width: 2560, height: 1440), CGSize(width: 3840, height: 2160)] {
            let metrics = GridMetrics.compute(for: size)
            #expect(metrics.iconSize >= 48)
            #expect(metrics.iconSize <= 96)
            #expect(metrics.iconSize <= metrics.cellSize.width)
        }
    }

    @Test func gridFitsInsideUsableWidth() {
        let size = CGSize(width: 1440, height: 900)
        let metrics = GridMetrics.compute(for: size)
        let total = CGFloat(metrics.columns) * metrics.cellSize.width
            + CGFloat(metrics.columns - 1) * metrics.columnGap
            + metrics.sideMargin * 2
        #expect(total <= size.width + 0.5)
    }

    @Test func pageSplitting() {
        let metrics = GridMetrics.compute(for: CGSize(width: 1440, height: 900)) // 35 per page
        let pages = metrics.pages(of: Array(0..<100))
        #expect(pages.count == 3)
        #expect(pages[0].count == 35)
        #expect(pages[2].count == 30)
        #expect(metrics.page(ofItem: 70) == 2)
        #expect(metrics.pageCount(forItemCount: 100) == 3)
        #expect(metrics.pageCount(forItemCount: 0) == 0)
        #expect(metrics.pages(of: [Int]()).isEmpty)
    }
}
