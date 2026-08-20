import Foundation
import JBarCore

/// The panel's view of "something that answers queries". The real implementation is `SearchEngine`
/// (JBarCore actor); `DemoSearchProvider` is the `JBAR_DEMO=1` stand-in so the UI can be exercised
/// without an index. Implementations must be safe to call from the main actor and may take as long
/// as they like — the panel applies only the newest response (by `requestId`).
protocol SearchProviding: Sendable {
    /// Run one query. `limit` = `Config.maxResults`, `appsFirstCap` = `Config.appsFirstCap`.
    func runSearch(_ raw: String, limit: Int, appsFirstCap: Int) async -> SearchResponse
}

extension SearchEngine: SearchProviding {
    func runSearch(_ raw: String, limit: Int, appsFirstCap: Int) async -> SearchResponse {
        await search(raw, limit: limit, appsFirstCap: appsFirstCap)
    }
}
