import CmuxNextCompat

/// Waits for main-actor observable state to reach a condition: event-driven
/// (an `ObservationStream`), bounded by a one-shot `DemandTimer`, no polling.
/// For a daemon reply that can arrive before the state mirror shows its
/// result (a created browser profile, a tab moved to another profile).
public struct ObservedCondition: Sendable {
    public let owner: String
    public let deadline: Duration

    public init(owner: String, deadline: Duration) {
        self.owner = owner
        self.deadline = deadline
    }

    /// True once `condition` holds, false when the deadline passes first.
    @MainActor
    public func wait(_ condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        if condition() { return true }
        let outcome = FirstOutcome<Bool>()
        let timer = DemandTimer(owner: owner)
        let watch = Task { @MainActor in
            for await met in ObservationStream(condition) where met { return outcome.resolve(true) }
        }
        timer.schedule(after: deadline) { outcome.resolve(false) }
        let met = await outcome.value()
        watch.cancel()
        timer.cancel()
        return met
    }
}
