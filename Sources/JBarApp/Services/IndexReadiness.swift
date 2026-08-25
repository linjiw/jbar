import JBarCore

/// Assistant and Organize both require a complete immutable generation. A partial index is useful
/// for launcher typing, but it must never masquerade as a complete whole-computer file search.
enum IndexReadiness {
    static func waitMessage(for status: IndexStatus) -> String? {
        if status.hitItemCap || !status.cappedDirs.isEmpty {
            return "The local index reached a configured scan limit and is incomplete. Narrow the indexed roots or limits, rebuild the index, then try again."
        }
        if !status.deniedPaths.isEmpty {
            return "The local index could not read one or more configured locations and is incomplete. Restore file access or narrow the indexed roots, rebuild the index, then try again."
        }
        switch status.phase {
        case .idle:
            return status.itemCount == 0
                ? "The local index is starting. Try again after JBar finishes indexing."
                : nil
        case .updating:
            return status.itemCount == 0
                ? "The local index is updating. Try again when indexed files are available."
                : nil
        case .loadingSnapshot, .scanningApps, .crawling:
            let count = max(0, status.itemCount)
            return count > 0
                ? "The local index is still building (\(count.formatted()) items so far). Try again when indexing finishes."
                : "The local index is still building. Try again when indexing finishes."
        case .failed:
            return "The local index is unavailable. Use the JBar menu to rebuild it, then try again."
        }
    }
}
