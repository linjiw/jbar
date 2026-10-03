import Foundation
import JBarCore

public enum CLICommand: String, Sendable { case search, index, status, serve, help, version }
public enum CLIFormat: String, Sendable { case text, json, jsonl, paths, null }

public struct CLIError: Error, LocalizedError, Sendable {
    public let code: Int32
    public let message: String
    public init(_ message: String, code: Int32 = 2) { self.message = message; self.code = code }
    public var errorDescription: String? { message }
}

/// Argument parsing is separate from I/O so help and invalid invocations never touch the filesystem.
public struct CLIOptions: Sendable {
    public var command: CLICommand = .help
    public var format: CLIFormat = .text
    public var query = ""
    public var roots: [String] = []
    public var configPath: String?
    public var cacheDirectory: String?
    public var limit = 40
    public var maxItems: Int?
    public var maxDepth: Int?
    public var includeHidden = false
    public var maxAge: TimeInterval = 7 * 86_400
    public var allowStale = false

    public init() {}

    public static func parse(_ args: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        guard let first = args.first else { return options }
        if first == "--help" || first == "-h" { return options }
        if first == "--version" { options.command = .version; return options }
        guard let command = CLICommand(rawValue: first) else { throw CLIError("Unknown command: \(first). Run jbar-cli help.") }
        options.command = command
        if command == .help || command == .version { return options }
        var positionals: [String] = []
        var i = 1
        var positionalOnly = false
        while i < args.count {
            let argument = args[i]
            if positionalOnly { positionals.append(argument); i += 1; continue }
            func value() throws -> String {
                guard i + 1 < args.count else { throw CLIError("\(argument) requires a value.") }
                i += 1
                return args[i]
            }
            func integer(_ range: ClosedRange<Int>) throws -> Int {
                let raw = try value()
                guard let number = Int(raw), range.contains(number) else {
                    throw CLIError("\(argument) must be an integer in \(range.lowerBound)...\(range.upperBound).")
                }
                return number
            }
            switch argument {
            case "--": positionalOnly = true
            case "--help", "-h": options.command = .help; return options
            case "--root":
                guard options.roots.count < SafetyLimits.maxRootEntries else { throw CLIError("Too many roots.") }
                options.roots.append(try value())
            case "--config": options.configPath = try value()
            case "--cache-dir": options.cacheDirectory = try value()
            case "--format":
                guard let format = CLIFormat(rawValue: try value()) else { throw CLIError("Format must be text, json, jsonl, paths, or null.") }
                options.format = format
            case "--json": options.format = .json
            case "--jsonl": options.format = .jsonl
            case "--limit": options.limit = try integer(SafetyLimits.maxResults)
            case "--max-items": options.maxItems = try integer(SafetyLimits.maxIndexedItems)
            case "--max-depth": options.maxDepth = try integer(SafetyLimits.maxDepth)
            case "--max-age":
                let raw = try value()
                guard let seconds = Double(raw), seconds.isFinite, seconds >= 0, seconds <= 366 * 86_400 else {
                    throw CLIError("--max-age must be seconds in 0...31622400.")
                }
                options.maxAge = seconds
            case "--include-hidden": options.includeHidden = true
            case "--allow-stale": options.allowStale = true
            default:
                if argument.hasPrefix("-") { throw CLIError("Unknown option: \(argument).") }
                positionals.append(argument)
            }
            i += 1
        }
        guard command == .search || positionals.isEmpty else { throw CLIError("\(command.rawValue) accepts no positional arguments.") }
        if command == .search {
            options.query = positionals.joined(separator: " ")
            try validateQuery(options.query)
        }
        guard command == .search || (options.format != .paths && options.format != .null) else {
            throw CLIError("paths and null formats are supported only for search.")
        }
        return options
    }

    public static func validateQuery(_ query: String) throws {
        guard SafetyLimits.utf8Fits(query, maxBytes: SafetyLimits.maxQueryUTF8Bytes),
              query.count <= SafetyLimits.maxQueryCharacters,
              !SafetyLimits.containsNULByte(query),
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError("Query must be nonempty, contain no NUL, and fit \(SafetyLimits.maxQueryCharacters) characters / \(SafetyLimits.maxQueryUTF8Bytes) UTF-8 bytes.")
        }
        // The core intentionally bounds launcher terms. A CLI must not silently drop agent constraints.
        if QueryParser.parse(query).mode == .search,
           query.split(whereSeparator: { $0.isWhitespace }).count > QueryParser.maxTerms {
            throw CLIError("At most \(QueryParser.maxTerms) search terms are supported.")
        }
    }
}
