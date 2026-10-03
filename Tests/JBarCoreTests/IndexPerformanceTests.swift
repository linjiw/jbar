import XCTest
@testable import JBarCore

/// Opt-in, deterministic index measurements. Run in Release with
/// JBAR_INDEX_BENCHMARK_ITEMS=100000 swift test -c release --filter IndexPerformanceTests.
/// Reports medians; timings are diagnostic and never assertions on machine speed.
final class IndexPerformanceTests: XCTestCase {
    func testSnapshotAndMergePerformance() throws {
        guard let raw = ProcessInfo.processInfo.environment["JBAR_INDEX_BENCHMARK_ITEMS"] else {
            throw XCTSkip("set JBAR_INDEX_BENCHMARK_ITEMS to run index benchmarks")
        }
        guard let count = Int(raw), (1...1_000_000).contains(count) else {
            XCTFail("JBAR_INDEX_BENCHMARK_ITEMS must be between 1 and 1000000")
            return
        }
        let builder = IndexBuilder()
        builder.reserve(items: count, dirs: 1_001)
        let root = builder.addRoot("/benchmark")
        var directories: [Int32] = []
        for directory in 0..<1_000 {
            directories.append(builder.addDir(parent: root, name: "project-\(directory)"))
        }
        for item in 0..<count {
            let name = item % 4 == 0 ? "研究报告-\(item).pdf" : "project-report-\(item).swift"
            let kind: ItemKind = item % 4 == 0 ? .document : .code
            XCTAssertGreaterThanOrEqual(builder.addItem(
                dir: directories[item % directories.count], name: name,
                analyzed: TextAnalyzer.analyze(name), kind: kind,
                flags: [], mtime: nil, depth: 1,
                ext: item % 4 == 0 ? "pdf" : "swift"
            ), 0)
        }
        let store = builder.build(generation: 1, builtAt: Date(timeIntervalSince1970: 1_700_000_000))
        let encoded = try Snapshot.encode(store, headerHash: 1)
        let keep = Array(0..<count)
        var encode: [Double] = [], decode: [Double] = [], merge: [Double] = [], rebrand: [Double] = []
        for _ in 0..<5 {
            var start = ContinuousClock.now
            let data = try Snapshot.encode(store, headerHash: 1)
            encode.append(seconds(start.duration(to: .now)))
            XCTAssertEqual(data.count, encoded.count)
            start = .now
            let loaded = Snapshot.decode(encoded, expectedHeaderHash: 1, maxItems: count, rootAllowance: 1)
            decode.append(seconds(start.duration(to: .now)))
            XCTAssertEqual(loaded?.count, count)
            start = .now
            let merged = StoreMerge.merge(base: store, keep: keep, extra: .empty, rootMap: [:],
                                          generation: 2, fsEventId: 1, maxItems: count, rootAllowance: 1)
            merge.append(seconds(start.duration(to: .now)))
            XCTAssertEqual(merged?.count, count)
            start = .now
            let rebranded = StoreMerge.rebrand(store, generation: 2, fsEventId: 2)
            rebrand.append(seconds(start.duration(to: .now)))
            XCTAssertEqual(rebranded.count, count)
        }
        let report: [String: Any] = [
            "items": count, "snapshotBytes": encoded.count, "samples": 5,
            "snapshotEncodeMedianMS": median(encode) * 1_000,
            "snapshotDecodeMedianMS": median(decode) * 1_000,
            "unchangedStoreMergeMedianMS": median(merge) * 1_000,
            "metadataRebrandMedianMS": median(rebrand) * 1_000,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("JBAR_INDEX_BENCHMARK \(String(decoding: data, as: UTF8.self))")
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
}
