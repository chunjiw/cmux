import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Simulates a slow synchronous file read. The semaphore is the test's I/O
/// stall, not a production lock; the deadline makes a main-actor regression fail
/// instead of deadlocking the hosted test process.
struct StartupSnapshotReadProbeStore: SessionSnapshotStoring {
    typealias SnapshotValue = AppSessionSnapshot
    let releaseRead = DispatchSemaphore(value: 0)
    let reads: AsyncStream<Bool>
    private let readContinuation: AsyncStream<Bool>.Continuation

    init() {
        let stream = AsyncStream<Bool>.makeStream()
        reads = stream.stream
        readContinuation = stream.continuation
    }

    func loadOutcome(fileURL: URL) -> SessionSnapshotLoadOutcome<AppSessionSnapshot> {
        readContinuation.yield(Thread.isMainThread)
        #expect(releaseRead.wait(timeout: .now() + 5) == .success)
        readContinuation.finish()
        return .missing
    }

    func defaultSnapshotFileURL() -> URL? { URL(fileURLWithPath: "/unused/startup-session.json") }
    func manualRestoreSnapshotFileURL() -> URL? { nil }
    func snapshotFileURL(bundleIdentifier: String) -> URL? { nil }
    func load(fileURL: URL?) -> AppSessionSnapshot? { nil }
    func loadReopenSessionSnapshot(fileURL: URL?) -> AppSessionSnapshot? { nil }
    func loadStartupSnapshot() -> AppSessionSnapshot? { nil }
    func syncManualRestoreSnapshotCache() { Issue.record("Unexpected backup write") }
    func save(_ snapshot: AppSessionSnapshot, fileURL: URL?) -> Bool {
        Issue.record("Unexpected snapshot write")
        return false
    }
    func removeSnapshot(fileURL: URL?) { Issue.record("Unexpected snapshot removal") }
    func importableSnapshot(fileURL: URL) -> Result<SessionSnapshotImport<AppSessionSnapshot>, SessionSnapshotImportError> {
        .failure(.fileNotFound(fileURL))
    }
    func importableSnapshot(bundleIdentifier: String) -> Result<SessionSnapshotImport<AppSessionSnapshot>, SessionSnapshotImportError> {
        .failure(.fileNotFound(URL(fileURLWithPath: "/unused/startup-session.json")))
    }
    func exportSnapshot(to destination: URL, overwrite: Bool) -> Result<URL, SessionSnapshotExportError> {
        .failure(.noSnapshot)
    }
    func preserveNewerSchemaSnapshot(fileURL: URL) -> URL? { nil }
    func preserveNewerSchemaSnapshotBeforeReplacing(fileURL: URL) -> Bool { true }
    func preserveUnusableSnapshot(fileURL: URL) -> URL? { nil }
    func archiveSnapshotToHistory(fileURL: URL, richness: SessionSnapshotRichness, archivedAt: Date) -> SessionSnapshotHistoryEntry? { nil }
    func historyEntries() -> [SessionSnapshotHistoryEntry] { [] }
}
