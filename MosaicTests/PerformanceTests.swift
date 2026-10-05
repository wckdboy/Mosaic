import XCTest

@testable import Mosaic

// These are repeatable simulator baselines, not device FPS or battery claims.
// Explicit generous time ceilings catch algorithmic regressions on shared runners.
@MainActor final class PerformanceTests: XCTestCase {
    private func items(_ count: Int) -> [MediaItem] {
        (0..<count).map { MediaItem(id: "\($0)", name: "Trip_\($0).jpg", kind: .photo, date: .distantPast) }
    }
    func testCanvasViewportLookupAtFiftyThousandItems() {
        let layout = MosaicCanvasLayout()
        layout.clusters = [MosaicCluster(id: "all", title: "All", items: items(50_000))]
        layout.prepare()
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let start = ProcessInfo.processInfo.systemUptime
            for index in 0..<1000 {
                let rect = CGRect(x: 0, y: index * 150, width: 430, height: 900)
                XCTAssertLessThan(layout.layoutAttributesForElements(in: rect)!.count, 60)
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.0)
        }
    }
    func testNameGroupingTenThousandItems() {
        let library = items(10_000)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let start = ProcessInfo.processInfo.systemUptime
            let result = MosaicClusterBuilder.clusters(
                items: library, mode: .name, descriptors: [:], sentiments: [:])
            XCTAssertEqual(result.flatMap(\.items).count, library.count)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3.0)
        }
    }
    func testBatchRenameTenThousandCollidingNames() {
        let library = items(10_000)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let start = ProcessInfo.processInfo.systemUptime
            let result = OrganizationPlanner.plan(
                items: library,
                options: OrganizationOptions(pattern: "Same", grouping: .none), descriptors: [:])
            XCTAssertEqual(Set(result.map(\.name)).count, library.count)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 4.0)
        }
    }
    func testEmptyFilterTenThousandItems() {
        let library = items(10_000)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            XCTAssertEqual(
                library.filter { MosaicFilter().matches($0, favorites: [], text: [:]) }.count, library.count)
        }
    }
}
