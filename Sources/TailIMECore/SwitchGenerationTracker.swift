import Foundation

/// Thread-safe generation & in-flight direct-IPC tracker for asynchronous input-source switching.
///
/// Guarantees two invariants across the main thread and the off-main TSM IPC serial queue:
/// 1. Any queued TSM IPC send checks `isCurrent(gen)` before executing so superseded requests abort immediately.
/// 2. While an earlier direct TSM IPC is still in-flight (`hasInFlightDirectSwitch == true`), a newer switch
///    to the *currently reported* language (e.g., EN -> in-flight KO -> EN) is NEVER short-circuited and NEVER
///    downgraded to a relative hotkey toggle — it queues its deterministic absolute target behind the in-flight
///    IPC on the same serial queue so the final OS state strictly matches the latest request.
public final class SwitchGenerationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _generation: UInt64 = 0
    private var _inFlightDirectCount: Int = 0

    public init() {}

    @discardableResult
    public func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        _generation &+= 1
        return _generation
    }

    public var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _generation
    }

    public func isCurrent(_ gen: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _generation == gen
    }

    public func beginInFlightDirectSwitch() {
        lock.lock()
        _inFlightDirectCount += 1
        lock.unlock()
    }

    public func endInFlightDirectSwitch() {
        lock.lock()
        _inFlightDirectCount = max(0, _inFlightDirectCount - 1)
        lock.unlock()
    }

    public var hasInFlightDirectSwitch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _inFlightDirectCount > 0
    }

    /// Returns true ONLY when the currently reported source already matches the target AND
    /// no older direct TSM IPC is in-flight that could still change the source away from target.
    public func canShortCircuitAlreadyAtTarget(_ alreadyMatches: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return alreadyMatches && _inFlightDirectCount == 0
    }
}
