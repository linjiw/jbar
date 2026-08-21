import XCTest
import JBarCore
@testable import JBarApp

final class ConcurrencyBoundaryTests: XCTestCase {
    func testHeadlessStatusTrackerSupportsConcurrentCallbacksAndPolling() {
        let tracker = CLI.StatusTracker()
        var busy = IndexStatus()
        busy.phase = .crawling(progress: 1)
        tracker.observe(busy)

        let idle: IndexStatus = {
            var status = IndexStatus()
            status.phase = .idle
            return status
        }()
        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            tracker.observe(idle)
            _ = tracker.isReady
        }

        XCTAssertTrue(tracker.isReady)
    }
}
