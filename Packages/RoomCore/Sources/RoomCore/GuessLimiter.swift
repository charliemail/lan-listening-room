import Foundation

/// Per-source wrong-code counter: after `maxFailures` in a row the source is locked out for `lockout`.
/// Keyed by remote host (not connection) so reconnecting doesn't reset it.
public struct GuessLimiter: Sendable {
    public let maxFailures: Int
    public let lockout: TimeInterval
    private var failures: [String: Int] = [:]
    private var lockedUntil: [String: Date] = [:]

    public init(maxFailures: Int = 5, lockout: TimeInterval = 30) {
        self.maxFailures = maxFailures
        self.lockout = lockout
    }

    public func isLocked(_ source: String, now: Date) -> Bool {
        lockedUntil[source].map { now < $0 } ?? false
    }

    public mutating func recordFailure(_ source: String, now: Date) {
        let count = failures[source, default: 0] + 1
        if count >= maxFailures {
            lockedUntil[source] = now.addingTimeInterval(lockout)
            failures[source] = 0
        } else {
            failures[source] = count
        }
    }

    public mutating func recordSuccess(_ source: String) {
        failures[source] = nil
        lockedUntil[source] = nil
    }
}

/// Tracks the last time each peer was heard from; silence (a paused song) is not a disconnect,
/// only missing heartbeats are.
public struct Liveness<Key: Hashable & Sendable>: Sendable {
    public let timeout: TimeInterval
    private var lastSeen: [Key: Date] = [:]

    public init(timeout: TimeInterval = RoomProtocol.heartbeatTimeout) {
        self.timeout = timeout
    }

    public mutating func touch(_ key: Key, now: Date) { lastSeen[key] = now }
    public mutating func forget(_ key: Key) { lastSeen[key] = nil }

    public func expired(now: Date) -> [Key] {
        lastSeen.filter { now.timeIntervalSince($0.value) > timeout }.map(\.key)
    }
}
