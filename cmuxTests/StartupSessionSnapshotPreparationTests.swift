import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct StartupSessionSnapshotPreparationTests {
    @MainActor
    @Test
    func startupSnapshotReadLeavesMainActorResponsive() async throws {
        let probe = StartupSnapshotReadProbeStore()
        let previousDelegate = AppDelegate.shared
        let delegate = AppDelegate(sessionSnapshotStore: probe)
        // Avoid starting app services in this isolated delegate when preparation
        // finishes. Terminating during preparation must still release its barrier.
        delegate.isTerminatingApp = true
        defer {
            probe.releaseRead.signal()
            AppDelegate.shared = previousDelegate
        }

        delegate.prepareStartupSessionSnapshotIfNeeded()
        var reads = probe.reads.makeAsyncIterator()
        let readWasOnMainThread = try #require(await reads.next())
        #expect(!readWasOnMainThread)
        // This line can execute while the file read is blocked only if startup
        // yielded the main actor. The old synchronous path times out in the store.
        probe.releaseRead.signal()
        _ = await reads.next()
    }
}
