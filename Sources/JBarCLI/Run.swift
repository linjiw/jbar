import Darwin
import Foundation

public let jbarCLIVersion = "0.2.0"

public let jbarCLIUsage = """
jbar-cli \(jbarCLIVersion) — local filename search and indexing for macOS agents

  jbar-cli index [options]                crawl explicitly; save only complete indexes
  jbar-cli search [options] -- QUERY      search an existing snapshot; never auto-crawl
  jbar-cli status [options]               report snapshot coverage, age and configuration
  jbar-cli serve [options]                JSONL requests on stdin; retain index in memory
  jbar-cli help | --help | --version

  --root PATH          repeatable scope; relative paths and ~/ are accepted
  --config FILE        read JBar JSON config; missing explicit files are errors
  --cache-dir DIR      independent CLI cache (default ~/Library/Caches/com.linji.jbar.cli)
  --format FORMAT      text | json | jsonl | paths | null (last two: search only)
  --json | --jsonl      output-format shortcuts; serve always uses JSONL
  --limit N            1...500 returned rows (default 40)
  --max-items N        1...2000000 (default from config: 1000000)
  --max-depth N        0...64 (default from config: 12)
  --include-hidden     index hidden entries (changes cache identity)
  --max-age SECONDS    reject old snapshots (default 604800, maximum 31622400)
  --allow-stale        explicitly allow an older snapshot

Queries: fuzzy filename terms (AND, maximum 6), .pdf extension filter,
absolute/~/directory prefixes for snapshot browsing inside descended indexed directories.
Trailing whitespace makes the last term a substring. No file-content search.

Serve: {"id":"1","query":"report","limit":20}; command search (default), status, quit.
It emits one ready record, then one JSON record per request. No network or GUI startup.
Exit: 0 success, 1 I/O/runtime error, 2 invalid input, 3 missing/invalid/stale index,
4 incomplete crawl/search. No matches is a successful search.
"""

public enum CLIEncoding {
    public static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func search(_ output: CLISearchOutput, format: CLIFormat) throws -> String {
        switch format {
        case .json: return try json(output) + "\n"
        case .jsonl:
            var records = [try json(SearchMetadata(output: output))]
            for result in output.results { records.append(try json(ResultRecord(type: "result", result: result))) }
            return records.joined(separator: "\n") + "\n"
        case .paths:
            guard output.results.allSatisfy({ !$0.path.contains("\n") && !$0.path.contains("\r") }) else {
                throw CLIError("A result path contains a newline. Use --format null, json, or jsonl.")
            }
            return output.results.map { $0.path + "\n" }.joined()
        case .null: return output.results.map { $0.path + "\0" }.joined()
        case .text:
            let count = output.totalMatchesIsComplete ? String(output.totalMatches) : "at least \(output.totalMatches)"
            let header = "\(count) matches; \(output.returnedCount) returned; \(String(format: "%.3f", output.elapsedSeconds * 1_000)) ms search; source=\(output.source); snapshot-age=\(Int(output.index.ageSeconds))s\(output.index.stale ? " (stale)" : "")\n"
            return header + output.results.map { "\($0.kind)\t\(String(reflecting: $0.path))\n" }.joined()
        }
    }

    private struct ResultRecord: Encodable { let type: String; let result: CLIResult }
    private struct SearchMetadata: Encodable {
        let type = "search-metadata"
        let query: String
        let source: String
        let mode: String
        let elapsedSeconds: TimeInterval
        let startupSeconds: TimeInterval
        let totalMatches: Int
        let totalMatchesIsComplete: Bool
        let hasMoreResults: Bool?
        let returnedCount: Int
        let index: CLIIndexMetadata
        init(output: CLISearchOutput) {
            query = output.query; source = output.source; mode = output.mode; elapsedSeconds = output.elapsedSeconds
            startupSeconds = output.startupSeconds; totalMatches = output.totalMatches
            totalMatchesIsComplete = output.totalMatchesIsComplete; hasMoreResults = output.hasMoreResults
            returnedCount = output.returnedCount; index = output.index
        }
    }
}

public func runJBarCLI(arguments: [String]) async -> Int32 {
    do {
        let options = try CLIOptions.parse(arguments)
        switch options.command {
        case .help: try CLIIO.write(jbarCLIUsage + "\n", to: STDOUT_FILENO); return 0
        case .version: try CLIIO.write("jbar-cli \(jbarCLIVersion)\n", to: STDOUT_FILENO); return 0
        default: break
        }
        let settings = try CLIIndexSettings(options: options)
        switch options.command {
        case .index:
            let index = try CLIIndex.build(settings: settings)
            let output = CLIStatusOutput(type: "index", id: nil, index: index.metadata(), startupSeconds: index.startupSeconds)
            try CLIIO.write(try statusText(output, format: options.format), to: STDOUT_FILENO)
            return index.complete ? 0 : 4
        case .status:
            let index = try CLIIndex.load(settings: settings, permitStale: true)
            let output = CLIStatusOutput(type: "status", id: nil, index: index.metadata(), startupSeconds: index.startupSeconds)
            try CLIIO.write(try statusText(output, format: options.format), to: STDOUT_FILENO)
            return 0
        case .search:
            let session = CLISearchSession(index: try CLIIndex.load(settings: settings))
            let output = try await session.search(query: options.query, limit: options.limit)
            try CLIIO.write(try CLIEncoding.search(output, format: options.format), to: STDOUT_FILENO)
            return output.totalMatchesIsComplete ? 0 : 4
        case .serve:
            let index = try CLIIndex.load(settings: settings)
            let session = CLISearchSession(index: index)
            try CLIIO.write(try CLIEncoding.json(CLIStatusOutput(type: "ready", id: nil,
                                                               index: index.metadata(), startupSeconds: index.startupSeconds)) + "\n", to: STDOUT_FILENO)
            return try await serve(session: session, defaultLimit: options.limit)
        case .help, .version: return 0
        }
    } catch {
        let failure = (error as? CLIError) ?? CLIError(error.localizedDescription, code: 1)
        // Errors are always machine-readable JSON on stderr; successful stdout remains pure.
        if let encoded = try? CLIEncoding.json(CLIErrorOutput(code: failure.code, error: failure.message)) {
            try? CLIIO.write(encoded + "\n", to: STDERR_FILENO)
        }
        return failure.code
    }
}

private func statusText(_ output: CLIStatusOutput, format: CLIFormat) throws -> String {
    if format == .json || format == .jsonl { return try CLIEncoding.json(output) + "\n" }
    let metadata = output.index
    return "\(metadata.itemCount) items; complete=\(metadata.complete); persisted=\(metadata.persisted); stale=\(metadata.stale); watching=false\n"
        + "built-at=\(metadata.builtAt); age=\(Int(metadata.ageSeconds))s; startup=\(String(format: "%.3f", output.startupSeconds))s\n"
        + "roots=\(metadata.roots.map { String(reflecting: $0) }.joined(separator: ", "))\n"
        + "snapshot=\(String(reflecting: metadata.snapshotPath))\n"
        + "denied=\(metadata.deniedPaths.count); unavailable-roots=\(metadata.unavailableRoots.count); capped-directories=\(metadata.cappedDirectories.count); hit-item-cap=\(metadata.hitItemCap); unsafe-skipped=\(metadata.unsafeEntriesSkipped)\n"
}

private func serve(session: CLISearchSession, defaultLimit: Int) async throws -> Int32 {
    var input = CLIInputReader()
    while true {
        var id: String?
        do {
            guard let line = try input.nextLine() else { return 0 }
            let request: CLIServeRequest
            do { request = try JSONDecoder().decode(CLIServeRequest.self, from: line) }
            catch {
                id = CLIServeRequest.errorCorrelationID(from: line)
                throw CLIError("Invalid JSONL request: \(error.localizedDescription)")
            }
            id = request.id
            let response = try await session.handle(request: request, defaultLimit: defaultLimit)
            switch response {
            case .search(let output): try CLIIO.write(try CLIEncoding.json(output) + "\n", to: STDOUT_FILENO)
            case .status(let output): try CLIIO.write(try CLIEncoding.json(output) + "\n", to: STDOUT_FILENO)
            case .quit:
                try CLIIO.write("{\"type\":\"bye\"}\n", to: STDOUT_FILENO)
                return 0
            }
        } catch {
            let failure = (error as? CLIError) ?? CLIError(error.localizedDescription, code: 1)
            try CLIIO.write(try CLIEncoding.json(CLIErrorOutput(id: id, code: failure.code, error: failure.message)) + "\n", to: STDOUT_FILENO)
            if failure.code == 1 { return 1 }
        }
    }
}

private enum CLIIO {
    static func write(_ value: String, to fd: Int32) throws {
        try Array(value.utf8).withUnsafeBytes { buffer in
            var position = 0
            while position < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress?.advanced(by: position), buffer.count - position)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CLIError("Output write failed (errno \(errno)).", code: 1)
                }
                guard count > 0 else { throw CLIError("Output write failed.", code: 1) }
                position += count
            }
        }
    }
}

/// Avoid readLine(): an agent's malformed line must not allocate unbounded memory. Overflow drains
/// exactly one line, reports an error, and lets the next request proceed. EOF with no newline works.
struct CLIInputReader {
    static let maximumLineBytes = 64 * 1_024
    private var pending: [UInt8] = []
    private var cursor = 0
    private let readBytes: () throws -> [UInt8]

    init(readBytes: (() throws -> [UInt8])? = nil) {
        self.readBytes = readBytes ?? {
            var buffer = [UInt8](repeating: 0, count: 4 * 1_024)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CLIError("Input read failed (errno \(errno)).", code: 1)
                }
                return Array(buffer.prefix(count))
            }
        }
    }

    mutating func nextLine() throws -> Data? {
        var line: [UInt8] = []
        var overflow = false
        while true {
            if cursor == pending.count {
                pending = try readBytes(); cursor = 0
                if pending.isEmpty {
                    if overflow { throw CLIError("JSONL line exceeds \(Self.maximumLineBytes) bytes.") }
                    return line.isEmpty ? nil : Data(line)
                }
            }
            let byte = pending[cursor]; cursor += 1
            if byte == 0x0A {
                if overflow { throw CLIError("JSONL line exceeds \(Self.maximumLineBytes) bytes.") }
                if line.last == 0x0D { line.removeLast() }
                return Data(line)
            }
            if !overflow {
                if line.count == Self.maximumLineBytes { overflow = true; line.removeAll(keepingCapacity: false) }
                else { line.append(byte) }
            }
        }
    }
}
