import Foundation
import JBarCore

/// The panel's view of "something that answers queries". The real implementation is `SearchEngine`
/// (JBarCore actor); `DemoSearchProvider` is the `JBAR_DEMO=1` stand-in so the UI can be exercised
/// without an index. Implementations must be safe to call from the main actor and may take as long
/// as they like — the panel applies only the newest response (by `requestId`).
protocol SearchProviding: Sendable {
    /// Run one query. `limit` = `Config.maxResults`, `appsFirstCap` = `Config.appsFirstCap`.
    func runSearch(_ raw: String, limit: Int, appsFirstCap: Int) async -> SearchResponse

    /// Execute an already-validated Assistant plan locally. Implementations must not send the
    /// request, result metadata, or paths to a model or network service.
    func runAssistedSearch(_ request: AssistedSearchRequest) async -> AssistedSearchResponse
}

extension SearchProviding {
    /// Test/demo providers that only model launcher search get a conservative, explicitly incomplete
    /// adapter. Production `SearchEngine` uses its native full-index implementation below.
    func runAssistedSearch(_ request: AssistedSearchRequest) async -> AssistedSearchResponse {
        let response = await runSearch(request.nameTerms.joined(separator: " "),
                                       limit: request.limit, appsFirstCap: request.limit)
        let rows = response.rows.filter { row in
            (request.kinds.isEmpty || request.kinds.contains(row.kind))
                && (request.extensions.isEmpty
                    || request.extensions.contains((row.path as NSString).pathExtension.lowercased()))
        }
        return AssistedSearchResponse(rows: Array(rows.prefix(request.limit)),
                                      totalMatches: rows.count, totalMatchesIsComplete: false,
                                      scannedItems: response.rows.count, inspectedSizes: 0,
                                      generation: response.generation, cancelled: response.cancelled)
    }
}

extension SearchEngine: SearchProviding {
    func runSearch(_ raw: String, limit: Int, appsFirstCap: Int) async -> SearchResponse {
        await search(raw, limit: limit, appsFirstCap: appsFirstCap)
    }

    func runAssistedSearch(_ request: AssistedSearchRequest) async -> AssistedSearchResponse {
        await assistedSearch(request)
    }
}
