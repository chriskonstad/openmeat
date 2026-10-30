import Foundation
import Synchronization

/// Injected "now" so estimators, alerts, sessions and the simulator are deterministic in tests.
public protocol TimeSource: Sendable {
    var now: Date { get }
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public var now: Date { Date() }
}

/// A clock you advance by hand. Thread-safe.
public final class ManualTimeSource: TimeSource {
    private let current: Mutex<Date>

    public init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = Mutex(start)
    }

    public var now: Date { current.withLock { $0 } }

    public func advance(by interval: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(interval) }
    }

    public func set(_ date: Date) {
        current.withLock { $0 = date }
    }
}

/// Runs time faster than real time from an anchor — demo mode and UI tests use this so a
/// 10-hour cook plays out in a minute.
public struct ScaledTimeSource: TimeSource {
    public let anchor: Date
    public let scale: Double
    private let base: any TimeSource

    public init(anchor: Date, scale: Double, base: any TimeSource = SystemTimeSource()) {
        self.anchor = anchor
        self.scale = scale
        self.base = base
    }

    public var now: Date {
        anchor.addingTimeInterval(base.now.timeIntervalSince(anchor) * scale)
    }

    /// The real (wall-clock) moment at which this source reads `date` — for UI that runs on the
    /// system clock, like Live Activity timers.
    public func wallClock(for date: Date) -> Date {
        anchor.addingTimeInterval(date.timeIntervalSince(anchor) / scale)
    }
}
