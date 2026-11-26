import Foundation

public enum HoldGateEventKind: Equatable, Sendable {
    case keyDown
    case keyUp
    case autoRepeat
    case flagsChanged
}

public struct HoldGateEntry<Event> {
    public let event: Event
    public let kind: HoldGateEventKind
    public let keyCode: Int64

    public init(event: Event, kind: HoldGateEventKind, keyCode: Int64) {
        self.event = event
        self.kind = kind
        self.keyCode = keyCode
    }
}

/// Strict FIFO event hold gate used during short input-source transition windows (local fast switch,
/// remote carrier switch, or Direct Tailscale UDP switch).
///
/// Invariants:
/// 1. While armed, ALL keyDown, keyUp, autorepeat, and flagsChanged events enter the FIFO queue in order.
/// 2. When discarding on focus change / mouse click (`discard: true`), buffered `keyDown`/`autoRepeat`
///    (and matching `keyUp`s whose `keyDown` was also buffered) are dropped so text never leaks into a new app,
///    HOWEVER any `flagsChanged` and any `keyUp` whose `keyDown` was ALREADY delivered BEFORE the gate armed
///    ARE STILL EMITTED so keys and modifiers NEVER get stuck!
/// 3. The queue is ALWAYS drained on: completion/ACK, hard timeout cap, capacity cap, focus change,
///    tap disable/re-enable, Secure Input activation, system sleep, or app termination.
public struct HoldGate<Event> {
    public enum FlushReason: String, Equatable, Sendable {
        case completed
        case timeout
        case capacityReached
        case focusChanged
        case tapDisabled
        case secureInput
        case systemSleep
        case terminating
        case manualReset
    }

    public let maxBufferedEvents: Int
    public private(set) var isArmed: Bool = false
    public private(set) var armedAt: TimeInterval = 0
    public private(set) var deadlineAt: TimeInterval = 0
    public private(set) var generation: UInt64 = 0
    private var queue: [HoldGateEntry<Event>] = []

    public var count: Int { queue.count }

    public init(maxBufferedEvents: Int = 64) {
        self.maxBufferedEvents = max(1, maxBufferedEvents)
    }

    /// Arms the hold gate for at most `maxDuration` seconds. Returns the new generation token.
    @discardableResult
    public mutating func arm(now: TimeInterval, maxDuration: TimeInterval) -> UInt64 {
        generation &+= 1
        isArmed = true
        armedAt = now
        deadlineAt = now + max(0.005, maxDuration)
        return generation
    }

    /// Enqueues an event with its key kind/code metadata if armed.
    /// Returns:
    /// - `buffered: true` if the caller should swallow (return nil from tap)
    /// - `overflowFlush`: non-nil array of events to replay immediately if capacity cap or deadline was hit
    public mutating func enqueueIfArmed(
        _ event: Event,
        kind: HoldGateEventKind,
        keyCode: Int64,
        now: TimeInterval
    ) -> (buffered: Bool, overflowFlush: [Event]?) {
        guard isArmed else {
            return (false, nil)
        }
        let entry = HoldGateEntry(event: event, kind: kind, keyCode: keyCode)
        if now >= deadlineAt {
            var flushed = flush(reason: .timeout)
            flushed.append(event)
            return (true, flushed)
        }
        queue.append(entry)
        if queue.count >= maxBufferedEvents {
            let flushed = flush(reason: .capacityReached)
            return (true, flushed)
        }
        return (true, nil)
    }

    /// Flushes and disarms the gate, returning events to emit in exact FIFO order.
    /// When `discard` is true (focus changed / mouse click):
    /// - Drops newly buffered `keyDown`s, `autoRepeat`s, and `keyUp`s paired with buffered `keyDown`s
    /// - Preserves `flagsChanged` and orphan `keyUp`s (whose `keyDown` was already delivered before arming!)
    ///   to guarantee zero stuck keys or stuck modifiers!
    public mutating func flush(reason: FlushReason, discard: Bool = false) -> [Event] {
        isArmed = false
        armedAt = 0
        deadlineAt = 0
        let items = queue
        queue.removeAll(keepingCapacity: true)

        guard discard else {
            return items.map(\.event)
        }

        var bufferedDownCodes: Set<Int64> = []
        var safeToEmit: [Event] = []
        for entry in items {
            switch entry.kind {
            case .keyDown:
                bufferedDownCodes.insert(entry.keyCode)
            case .autoRepeat:
                // Never replay autorepeat into a newly focused window
                break
            case .keyUp:
                if bufferedDownCodes.remove(entry.keyCode) != nil {
                    // Paired with a buffered keyDown we dropped -> drop keyUp too
                } else {
                    // Its keyDown was ALREADY delivered before the gate armed -> MUST emit keyUp to avoid stuck key!
                    safeToEmit.append(entry.event)
                }
            case .flagsChanged:
                // Always emit modifier state transitions so Shift/Cmd/Ctrl/Opt never stick!
                safeToEmit.append(entry.event)
            }
        }
        return safeToEmit
    }

    /// Flushes only if the given generation matches (safe against stale async timeout timers).
    public mutating func flushIfGeneration(
        _ expectedGeneration: UInt64,
        reason: FlushReason,
        discard: Bool = false
    ) -> [Event]? {
        guard isArmed && generation == expectedGeneration else { return nil }
        return flush(reason: reason, discard: discard)
    }
}
