import Darwin
import Foundation
import JBarCore
import XCTest
@testable import JBarCLI

final class CLITests: XCTestCase {
    func testArgumentValidationAndLimits() throws {
        XCTAssertEqual(try CLIOptions.parse([]).command, .help)
        XCTAssertEqual(try CLIOptions.parse(["--version"]).command, .version)
        let options = try CLIOptions.parse(["search", "--limit", "500", "--json", "--", "report pdf"])
        XCTAssertEqual(options.limit, 500)
        XCTAssertEqual(options.format, .json)
        XCTAssertEqual(options.query, "report pdf")
        for args in [["search"], ["search", "--limit", "501", "q"], ["index", "extra"],
                     ["status", "--format", "paths"], ["search", "--max-age", "nan", "q"],
                     ["search", "one two three four five six seven"], ["search", "a\0b"]] {
            XCTAssertThrowsError(try CLIOptions.parse(args), "\(args)")
        }
    }

    func testScopesNormalizeDeduplicateAndSeparateCacheIdentity() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        var options = try fixtureOptions(fixture)
        options.roots = [fixture.path + "/files/", fixture.path + "/files"]
        let settings = try CLIIndexSettings(options: options)
        XCTAssertEqual(settings.roots.map(\.path), [fixture.path + "/files"])
        options.maxItems = 500
        let capped = try CLIIndexSettings(options: options)
        XCTAssertNotEqual(settings.snapshotURL, capped.snapshotURL)
        options.maxItems = nil
        options.includeHidden = true
        XCTAssertNotEqual(settings.headerHash, try CLIIndexSettings(options: options).headerHash)
        let sibling = fixture.appendingPathComponent("sibling")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        options.roots = [fixture.path + "/files", sibling.path]
        let ordered = try CLIIndexSettings(options: options)
        options.roots.reverse()
        let reversed = try CLIIndexSettings(options: options)
        XCTAssertEqual(ordered.snapshotURL, reversed.snapshotURL)
        XCTAssertEqual(reversed.roots.map(\.path), options.roots)
    }

    func testLegacyCoveragePolicyCacheIsNotReusedOrRemoved() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let settings = try CLIIndexSettings(options: fixtureOptions(fixture))
        let built = try CLIIndex.build(settings: settings)
        var legacyHash = FNV1a()
        legacyHash.update("jbar.cli.filename-index.v1")
        legacyHash.update(Snapshot.headerHash(exclusions: settings.exclusions,
                                              fileRoots: settings.roots.map(\.path), appRoots: [],
                                              maxItems: settings.maxItems))
        let legacyURL = settings.snapshotURL.deletingLastPathComponent()
            .appendingPathComponent("index-\(String(legacyHash.value, radix: 16)).bin")
        XCTAssertNotEqual(legacyURL, settings.snapshotURL)
        try Snapshot.write(built.store, to: legacyURL, headerHash: legacyHash.value)
        try FileManager.default.removeItem(at: settings.snapshotURL)
        assertCLIError(code: 3) { _ = try CLIIndex.load(settings: settings) }
        let priorBytes = try Data(contentsOf: legacyURL)
        _ = try CLIIndex.build(settings: settings)
        XCTAssertEqual(try Data(contentsOf: legacyURL), priorBytes)
        XCTAssertEqual(try CLIIndex.load(settings: settings).store.count, built.store.count)
    }

    func testOverlappingRootsRejectIndependentDepthCoverageInsteadOfDroppingScope() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let parent = fixture.path + "/files"
        let nested = fixture.appendingPathComponent("files/child/grandchild")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("target.txt"))
        var options = try fixtureOptions(fixture)
        options.maxDepth = 1
        options.roots = [parent]
        let parentIndex = try CLIIndex.build(settings: CLIIndexSettings(options: options))
        XCTAssertTrue(parentIndex.complete)
        let parentResult = try await CLISearchSession(index: parentIndex).search(query: "target", limit: 40)
        XCTAssertTrue(parentResult.results.isEmpty, "The parent depth-1 scope cannot reach the nested target.")
        options.roots = [parent, nested.path]
        assertCLIError(code: 2) { _ = try CLIIndexSettings(options: options) }
        options.roots.reverse()
        assertCLIError(code: 2) { _ = try CLIIndexSettings(options: options) }
        options.roots = [nested.path]
        let nestedSettings = try CLIIndexSettings(options: options)
        XCTAssertNotEqual(nestedSettings.snapshotURL, parentIndex.settings.snapshotURL)
        let nestedIndex = try CLIIndex.build(settings: nestedSettings)
        let nestedResult = try await CLISearchSession(index: nestedIndex).search(query: "target", limit: 40)
        XCTAssertEqual(nestedResult.results.map(\.name), ["target.txt"], "The nested root has independent depth-1 coverage.")
    }

    func testCombiningPathSeparatorsPreserveScopeTildeAndHiddenPolicy() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let home = fixture.path + "/files"
        let component = "\u{301}child"
        let child = URL(fileURLWithPath: home).appendingPathComponent(component)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data().write(to: child.appendingPathComponent("combining-note.txt"))
        var options = try fixtureOptions(fixture)
        let settings = try CLIIndexSettings(options: options, home: home)
        XCTAssertTrue(CLIIndexSettings.contains(child.path, under: home))
        XCTAssertEqual(try CLIIndexSettings.pathURL("~/" + component, home: home, workingDirectory: fixture.path).path, child.path)
        let session = CLISearchSession(index: try CLIIndex.build(settings: settings))
        let output = try await session.search(query: "~/" + component + "/", limit: 40)
        XCTAssertEqual(output.results.map(\.name), ["combining-note.txt"])
        do { _ = try await session.search(query: home + "/.\u{301}secret", limit: 40); XCTFail("hidden filter") }
        catch { XCTAssertEqual((error as? CLIError)?.code, 2) }
        options.roots = [home, child.path]
        assertCLIError(code: 2) { _ = try CLIIndexSettings(options: options, home: home) }
    }

    func testDirectoryLookupRetainsOneBoundedPathInsteadOfAllDirectoryPaths() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let longRoot = "/" + Array(repeating: String(repeating: "r", count: 100), count: 30).joined(separator: "/")
        let builder = IndexBuilder()
        let root = builder.addRoot(longRoot)
        let count = 10_000
        for item in 0..<count {
            let name = "directory-\(item)"
            let directory = builder.addDir(parent: root, name: name)
            builder.addItem(dir: root, name: name, analyzed: TextAnalyzer.analyze(name), kind: .folder,
                            flags: [], mtime: nil, depth: 1, ext: nil)
            builder.addItem(dir: directory, name: "target.txt", analyzed: TextAnalyzer.analyze("target.txt"), kind: .document,
                            flags: [], mtime: nil, depth: 2, ext: "txt")
        }
        var options = try fixtureOptions(fixture)
        options.roots = [longRoot]
        let settings = try CLIIndexSettings(options: options)
        let index = CLIIndex(settings: settings, store: builder.build(generation: 1), complete: true, stats: nil,
                             unavailableRoots: [], persisted: false, startupSeconds: 0)
        let session = CLISearchSession(index: index)
        for leaf in ["directory-9999", "directory-123", "directory-9999"] {
            let output = try await session.search(query: longRoot + "/" + leaf + "/", limit: 1)
            XCTAssertEqual(output.results.map(\.name), ["target.txt"])
            let metrics = await session.directoryLookupCacheMetrics()
            XCTAssertLessThanOrEqual(metrics.pathUTF8Bytes, SafetyLimits.maxPathUTF8Bytes)
            XCTAssertEqual(metrics.directoryIDs, 1)
        }
        XCTAssertEqual(index.store.dirs.count, count + 1)
    }

    func testTruncatedDefaultRootDiscoveryIsRejectedBeforeIndexing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        for number in 0...SafetyLimits.maxRootEntries {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent("home-root-\(number)"), withIntermediateDirectories: true)
        }
        var options = try fixtureOptions(fixture)
        options.roots = ["~"]
        assertCLIError(code: 4) { _ = try CLIIndexSettings(options: options, home: fixture.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path + "/cache"))
    }

    func testSnapshotRoundTripAndReadOnlySearchDoNotCrawl() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let settings = try CLIIndexSettings(options: fixtureOptions(fixture))
        let built = try CLIIndex.build(settings: settings)
        XCTAssertTrue(built.complete)
        let loaded = try CLIIndex.load(settings: settings)
        XCTAssertEqual(loaded.store.count, built.store.count)
        XCTAssertEqual(loaded.store.generation, built.store.generation)
        try Data().write(to: fixture.appendingPathComponent("files/new-after-index.txt"))
        let session = CLISearchSession(index: loaded)
        let report = try await session.search(query: "report pdf", limit: 500)
        XCTAssertEqual(report.results.map(\.name), ["report.pdf"])
        XCTAssertEqual(report.source, "snapshot")
        XCTAssertFalse(report.index.watching)
        XCTAssertFalse(report.index.contentIndexed)
        XCTAssertTrue(report.totalMatchesIsComplete)
        XCTAssertEqual(report.returnedCount, 1)
        let absent = try await session.search(query: "new-after-index", limit: 5)
        XCTAssertTrue(absent.results.isEmpty)
        XCTAssertEqual(loaded.store.count, built.store.count)
        let json = try CLIEncoding.search(report, format: .json)
        let decoded = try JSONDecoder().decode(CLISearchOutput.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.results.first?.path, fixture.path + "/files/report.pdf")
    }

    func testIncompleteCrawlDoesNotPersistAndMissingScopeFails() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        var options = try fixtureOptions(fixture)
        options.maxItems = 1
        let settings = try CLIIndexSettings(options: options)
        let index = try CLIIndex.build(settings: settings)
        XCTAssertFalse(index.complete)
        XCTAssertFalse(index.persisted)
        XCTAssertTrue(index.metadata().hitItemCap)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.snapshotURL.path))
        options.maxItems = nil
        options.roots = [fixture.path + "/absent-root"]
        let missing = try CLIIndex.build(settings: CLIIndexSettings(options: options))
        XCTAssertFalse(missing.complete)
        XCTAssertEqual(missing.metadata().unavailableRoots, options.roots)
    }

    func testMissingCorruptAndSymlinkSnapshotsFailClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let settings = try CLIIndexSettings(options: fixtureOptions(fixture))
        assertCLIError(code: 3) { _ = try CLIIndex.load(settings: settings) }
        try FileManager.default.createDirectory(at: settings.snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: settings.snapshotURL)
        assertCLIError(code: 3) { _ = try CLIIndex.load(settings: settings) }
        try FileManager.default.removeItem(at: settings.snapshotURL)
        try FileManager.default.createSymbolicLink(at: settings.snapshotURL, withDestinationURL: fixture.appendingPathComponent("files/report.pdf"))
        assertCLIError(code: 3) { _ = try CLIIndex.load(settings: settings) }
    }

    func testMatchingSnapshotHeaderCannotIntroduceOutOfScopePaths() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let settings = try CLIIndexSettings(options: fixtureOptions(fixture))
        _ = try CLIIndex.build(settings: settings)
        let builder = IndexBuilder()
        let outside = builder.addRoot(fixture.path + "/outside")
        builder.addItem(dir: outside, name: "secret.txt", analyzed: TextAnalyzer.analyze("secret.txt"),
                        kind: .document, flags: [], mtime: nil, depth: 1, ext: "txt")
        try Snapshot.write(builder.build(generation: 7), to: settings.snapshotURL, headerHash: settings.headerHash)
        assertCLIError(code: 3) { _ = try CLIIndex.load(settings: settings) }

        // The crawler legitimately retains a synthetic root parent; arbitrary siblings in that
        // parent are not part of the selected root even when all directory slices are valid.
        let siblingBuilder = IndexBuilder()
        let parent = siblingBuilder.addRoot(fixture.path)
        let root = siblingBuilder.addDir(parent: parent, name: "files")
        siblingBuilder.addItem(dir: parent, name: "outside", analyzed: TextAnalyzer.analyze("outside"),
                               kind: .folder, flags: [], mtime: nil, depth: 0, ext: nil)
        siblingBuilder.addItem(dir: root, name: "valid.txt", analyzed: TextAnalyzer.analyze("valid.txt"),
                               kind: .document, flags: [], mtime: nil, depth: 1, ext: "txt")
        try Snapshot.write(siblingBuilder.build(generation: 8), to: settings.snapshotURL, headerHash: settings.headerHash)
        assertCLIError(code: 3) { _ = try CLIIndex.load(settings: settings) }
    }

    func testSnapshotCoverageRejectsMissingRootAndIncorrectDepth() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        var options = try fixtureOptions(fixture)
        options.maxDepth = 1
        let settings = try CLIIndexSettings(options: options)
        _ = try CLIIndex.build(settings: settings)
        let builder = IndexBuilder()
        let root = builder.addRoot(settings.roots[0].path)
        let child = builder.addDir(parent: root, name: "child")
        builder.addItem(dir: child, name: "too-deep.txt", analyzed: TextAnalyzer.analyze("too-deep.txt"),
                        kind: .document, flags: [], mtime: nil, depth: 2, ext: "txt")
        try Snapshot.write(builder.build(generation: 9), to: settings.snapshotURL, headerHash: settings.headerHash)
        assertCLIError(code: 3) { _ = try CLIIndex.load(settings: settings) }
        let empty = IndexBuilder().build(generation: 10)
        try Snapshot.write(empty, to: settings.snapshotURL, headerHash: settings.headerHash)
        assertCLIError(code: 3) { _ = try CLIIndex.load(settings: settings) }
    }

    func testUnsafeSkippedSubtreeCannotReplaceCompleteSnapshot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let settings = try CLIIndexSettings(options: fixtureOptions(fixture))
        let prior = try CLIIndex.build(settings: settings)
        let priorBytes = try Data(contentsOf: settings.snapshotURL)
        var stats = CrawlStats()
        stats.skippedUnsafe = 1
        let replacement = IndexBuilder().build(generation: prior.store.generation + 1)
        XCTAssertFalse(try CLIIndex.persistCompleteSnapshot(replacement, settings: settings, stats: stats, unavailableRoots: []))
        XCTAssertEqual(try Data(contentsOf: settings.snapshotURL), priorBytes)
        XCTAssertEqual(try CLIIndex.load(settings: settings).store.generation, prior.store.generation)
        stats.skippedUnsafe = 0
        stats.unavailableRoots = settings.roots.map(\.path)
        XCTAssertFalse(try CLIIndex.persistCompleteSnapshot(replacement, settings: settings, stats: stats, unavailableRoots: []))
        XCTAssertEqual(try Data(contentsOf: settings.snapshotURL), priorBytes)
    }

    func testScopeValidationAllowsSiblingRootsAndDepthZeroPolicy() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let sibling = fixture.appendingPathComponent("sibling")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data().write(to: sibling.appendingPathComponent("sibling.txt"))
        var options = try fixtureOptions(fixture)
        options.roots.append(sibling.path)
        options.maxDepth = 0
        let settings = try CLIIndexSettings(options: options)
        let built = try CLIIndex.build(settings: settings)
        XCTAssertTrue(built.complete)
        XCTAssertEqual(try CLIIndex.load(settings: settings).store.count, built.store.count)
        options.roots.reverse()
        XCTAssertEqual(try CLIIndex.load(settings: CLIIndexSettings(options: options)).store.generation, built.store.generation)
    }

    func testStaleAndFutureSnapshotPolicy() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let settings = try CLIIndexSettings(options: fixtureOptions(fixture))
        let index = try CLIIndex.build(settings: settings)
        let staleNow = index.store.builtAt.addingTimeInterval(settings.maxAge + 1)
        assertCLIError(code: 3) { _ = try CLIIndex.load(settings: settings, now: staleNow) }
        let stale = try CLIIndex.load(settings: settings, permitStale: true, now: staleNow)
        XCTAssertTrue(stale.metadata(now: staleNow).stale)
        assertCLIError(code: 3) {
            _ = try CLIIndex.load(settings: settings, permitStale: true, now: index.store.builtAt.addingTimeInterval(-301))
        }
    }

    func testCachePermissionsAndDirectorySymlinkSafety() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        var options = try fixtureOptions(fixture)
        options.cacheDirectory = nil
        let owned = try CLIIndexSettings(options: options, home: fixture.path)
        let directory = owned.snapshotURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = try CLIIndex.build(settings: owned)
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(owned.snapshotURL), 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        assertCLIError(code: 1) { _ = try CLIIndex.load(settings: owned) }
        XCTAssertEqual(try permissions(directory), 0o755, "read-only loading must not chmod")
        _ = try CLIIndex.build(settings: owned)
        XCTAssertEqual(try permissions(directory), 0o700)
        let shared = fixture.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        options.cacheDirectory = shared.path
        let custom = try CLIIndexSettings(options: options, home: fixture.path)
        _ = try CLIIndex.build(settings: custom)
        XCTAssertEqual(try permissions(shared), 0o755)
        let link = fixture.appendingPathComponent("cache-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared)
        options.cacheDirectory = link.path
        assertCLIError(code: 1) { _ = try CLIIndex.load(settings: CLIIndexSettings(options: options)) }
    }

    func testValidatedCacheDescriptorCannotBeRedirectedByParentReplacement() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let settings = try CLIIndexSettings(options: fixtureOptions(fixture))
        let prior = try CLIIndex.build(settings: settings)
        let cache = settings.snapshotURL.deletingLastPathComponent()
        let moved = fixture.appendingPathComponent("previous-cache")
        let outside = fixture.appendingPathComponent("replacement-cache")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideSnapshot = outside.appendingPathComponent(settings.snapshotURL.lastPathComponent)
        let other = IndexBuilder().build(generation: prior.store.generation + 1)
        try Snapshot.write(other, to: outsideSnapshot, headerHash: settings.headerHash)
        let otherBytes = try Data(contentsOf: outsideSnapshot)
        let replacementBuilder = IndexBuilder()
        let replacementRoot = replacementBuilder.addRoot(settings.roots[0].path)
        replacementBuilder.addItem(dir: replacementRoot, name: "pinned-replacement.txt",
                                   analyzed: TextAnalyzer.analyze("pinned-replacement.txt"),
                                   kind: .document, flags: [], mtime: nil, depth: 1, ext: "txt")
        let replacement = replacementBuilder.build(generation: prior.store.generation + 2)
        let loaded = try CLIIndex.withValidatedCacheDirectory(settings: settings, create: false) { descriptor in
            try FileManager.default.moveItem(at: cache, to: moved)
            try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: outside)
            let read = Snapshot.read(from: settings.snapshotURL, parentDirectoryDescriptor: descriptor,
                                     expectedHeaderHash: settings.headerHash, maxItems: settings.maxItems,
                                     rootAllowance: settings.roots.count)
            // Both reader and writer borrow the same validated descriptor. Replacing its path
            // after validation must neither select nor overwrite the redirect target.
            try Snapshot.write(replacement, to: settings.snapshotURL, parentDirectoryDescriptor: descriptor,
                               headerHash: settings.headerHash)
            return read
        }
        XCTAssertEqual(loaded?.generation, prior.store.generation)
        XCTAssertEqual(try Data(contentsOf: outsideSnapshot), otherBytes)
        // Snapshot side-table JSON key order is unspecified. Verify decoded content rather than
        // comparing two independent encodings, and use a distinct generation to prove the write.
        let written = try XCTUnwrap(Snapshot.read(from: moved.appendingPathComponent(settings.snapshotURL.lastPathComponent),
                                                 expectedHeaderHash: settings.headerHash,
                                                 maxItems: settings.maxItems, rootAllowance: settings.roots.count))
        XCTAssertEqual(written.generation, replacement.generation)
        XCTAssertEqual(written.builtAt.timeIntervalSince1970, replacement.builtAt.timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written.path(of: 0), settings.roots[0].path + "/pinned-replacement.txt")
        XCTAssertEqual(written.itemKind(0), .document)
        assertCLIError(code: 1) { _ = try CLIIndex.load(settings: settings) }
    }

    func testSnapshotPathBrowsingStaysWithinDescendedScopeAndLimit() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let settings = try CLIIndexSettings(options: fixtureOptions(fixture))
        let session = CLISearchSession(index: try CLIIndex.build(settings: settings))
        try Data().write(to: fixture.appendingPathComponent("files/new-after-index.txt"))
        let browse = try await session.search(query: fixture.path + "/files/", limit: 1)
        XCTAssertEqual(browse.source, "snapshot")
        XCTAssertEqual(browse.mode, "directory")
        XCTAssertEqual(browse.results.count, 1)
        XCTAssertEqual(browse.hasMoreResults, true)
        let absent = try await session.search(query: fixture.path + "/files/new-after-index", limit: 40)
        XCTAssertTrue(absent.results.isEmpty)
        for path in [fixture.path + "/", fixture.path + "/files/node_modules/", fixture.path + "/files/.hidden/", fixture.path + "/files/.secret"] {
            do { _ = try await session.search(query: path, limit: 40); XCTFail("Allowed forbidden path \(path)") }
            catch { XCTAssertEqual((error as? CLIError)?.code, 2) }
        }
    }

    func testReplacedDirectorySymlinkCannotEscapeSnapshotScope() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let settings = try CLIIndexSettings(options: fixtureOptions(fixture))
        let index = try CLIIndex.build(settings: settings)
        let outside = fixture.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data().write(to: outside.appendingPathComponent("outside-secret.txt"))
        let child = fixture.appendingPathComponent("files/child")
        try FileManager.default.moveItem(at: child, to: fixture.appendingPathComponent("previous-child"))
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: outside)
        let output = try await CLISearchSession(index: index).search(query: child.path + "/", limit: 40)
        XCTAssertEqual(output.results.map(\.name), ["notes.txt"])
        XCTAssertEqual(output.source, "snapshot")
        XCTAssertTrue(output.results.allSatisfy { !$0.path.contains("outside-secret") })
    }

    func testServeRequestsPreserveIDsAndUseOneGeneration() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let settings = try CLIIndexSettings(options: fixtureOptions(fixture))
        let session = CLISearchSession(index: try CLIIndex.build(settings: settings))
        let first = try await session.handle(request: CLIServeRequest(id: "a", query: "report"), defaultLimit: 40)
        let second = try await session.handle(request: CLIServeRequest(id: "b", query: "report pdf"), defaultLimit: 40)
        guard case .search(let a) = first, case .search(let b) = second else { return XCTFail("expected search outputs") }
        XCTAssertEqual(a.id, "a")
        XCTAssertEqual(b.id, "b")
        XCTAssertEqual(a.index.generation, b.index.generation)
        guard case .status(let status) = try await session.handle(request: CLIServeRequest(command: "status"), defaultLimit: 40) else { return XCTFail("expected status") }
        XCTAssertEqual(status.index.generation, a.index.generation)
        guard case .quit = try await session.handle(request: CLIServeRequest(command: "quit"), defaultLimit: 40) else { return XCTFail("expected quit") }
        do { _ = try await session.handle(request: CLIServeRequest(query: "x", limit: 501), defaultLimit: 40); XCTFail("invalid limit") }
        catch { XCTAssertEqual((error as? CLIError)?.code, 2) }
        XCTAssertThrowsError(try JSONDecoder().decode(CLIServeRequest.self, from: Data("{\"query\":\"x\",\"content\":true}".utf8)))
    }

    func testRetainedSessionRejectsExpiredSnapshot() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let settings = try CLIIndexSettings(options: fixtureOptions(fixture))
        let index = try CLIIndex.build(settings: settings)
        let now = index.store.builtAt.addingTimeInterval(settings.maxAge + 1)
        do { _ = try await CLISearchSession(index: index).search(query: "report", limit: 40, now: now); XCTFail("expired session") }
        catch { XCTAssertEqual((error as? CLIError)?.code, 3) }
        var options = try fixtureOptions(fixture)
        options.allowStale = true
        let permitted = try CLIIndex.load(settings: CLIIndexSettings(options: options), now: now)
        let output = try await CLISearchSession(index: permitted).search(query: "report", limit: 40, now: now)
        XCTAssertTrue(output.index.stale)
    }

    func testJSONAndNullFormatsPreserveNewlinePaths() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let name = "newline\nname.txt"
        try Data().write(to: fixture.appendingPathComponent("files/" + name))
        let settings = try CLIIndexSettings(options: fixtureOptions(fixture))
        let output = try await CLISearchSession(index: CLIIndex.build(settings: settings)).search(query: "newline", limit: 40)
        XCTAssertEqual(output.results.first?.path, fixture.path + "/files/" + name)
        XCTAssertThrowsError(try CLIEncoding.search(output, format: .paths))
        XCTAssertTrue(try CLIEncoding.search(output, format: .null).hasSuffix("\0"))
        let jsonl = try CLIEncoding.search(output, format: .jsonl)
        XCTAssertEqual(jsonl.split(separator: "\n").count, 2)
        for line in jsonl.split(separator: "\n") { _ = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
    }

    func testBoundedInputReaderHandlesOverflowCRLFAndEOF() throws {
        var chunks = [Array((String(repeating: "x", count: CLIInputReader.maximumLineBytes + 1) + "\nvalid\r\nfinal").utf8)]
        var reader = CLIInputReader { chunks.isEmpty ? [] : chunks.removeFirst() }
        XCTAssertThrowsError(try reader.nextLine())
        XCTAssertEqual(try reader.nextLine(), Data("valid".utf8))
        XCTAssertEqual(try reader.nextLine(), Data("final".utf8))
        XCTAssertNil(try reader.nextLine())
    }

    func testRejectedRequestRetainsValidCorrelationIDWithoutAcceptingInvalidFields() throws {
        for line in ["{\"id\":\"unknown\",\"query\":\"x\",\"content\":true}",
                     "{\"id\":\"bad-query\",\"query\":false}",
                     "{\"id\":\"bad-limit\",\"query\":\"x\",\"limit\":\"many\"}"] {
            let bytes = Data(line.utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(CLIServeRequest.self, from: bytes))
            XCTAssertNotNil(CLIServeRequest.errorCorrelationID(from: bytes))
        }
        for line in ["{\"id\":3,\"query\":false}", "not JSON", "[]", "{}", "{\"id\":\"unfinished\""] {
            XCTAssertNil(CLIServeRequest.errorCorrelationID(from: Data(line.utf8)))
        }
        let oversized = Data(("{\"id\":\"" + String(repeating: "x", count: CLIInputReader.maximumLineBytes) + "\"}").utf8)
        XCTAssertNil(CLIServeRequest.errorCorrelationID(from: oversized))
    }

    func testExplicitMissingConfigDoesNotCreateAnything() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        var options = try fixtureOptions(fixture)
        options.configPath = fixture.path + "/missing-config.json"
        assertCLIError(code: 1) { _ = try CLIIndexSettings(options: options) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: options.configPath!))
    }

    private func makeFixture() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/cli-tests/fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("files/child"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("files/node_modules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("files/.hidden"), withIntermediateDirectories: true)
        for path in ["files/report.pdf", "files/report.swift", "files/child/notes.txt", "files/node_modules/forbidden.txt", "files/.secret"] {
            try Data().write(to: root.appendingPathComponent(path))
        }
        var config = Config.default
        config.fileRoots = [root.path + "/files"]
        config.appDirectories = []
        config.excludePaths = []
        try config.save(to: root.appendingPathComponent("config.json"))
        return root
    }

    private func fixtureOptions(_ fixture: URL) throws -> CLIOptions {
        try CLIOptions.parse(["index", "--root", fixture.path + "/files", "--config", fixture.path + "/config.json", "--cache-dir", fixture.path + "/cache"])
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)!.intValue & 0o777
    }

    private func assertCLIError(code: Int32, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        do { try body(); XCTFail("Expected CLIError \(code)", file: file, line: line) }
        catch { XCTAssertEqual((error as? CLIError)?.code, code, "\(error)", file: file, line: line) }
    }
}
