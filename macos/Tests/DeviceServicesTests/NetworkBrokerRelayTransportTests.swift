@testable import DeviceServices
import Foundation
import Testing

private enum KeepaliveTestFailure: Error {
    case pingFailed
    case timedOut
}

@Test func relayWebSocketKeepalivePingsPeriodically() async throws {
    let recorder = KeepalivePingRecorder()
    let keepalive = RelayWebSocketKeepalive(interval: .milliseconds(2)) {
        await recorder.recordPing()
    } onFailure: {
        await recorder.recordFailure()
    }

    try await waitForPings(2, recorder: recorder)
    keepalive.cancel()
    await keepalive.waitForCompletion()

    #expect(await recorder.count >= 2)
    #expect(await recorder.failureCount == 0)
}

@Test func relayWebSocketKeepaliveCancelsTheWebSocketAfterPingFailure() async throws {
    let target = KeepaliveTargetStub(failsPing: true)
    let keepalive = RelayWebSocketKeepalive(
        interval: .milliseconds(1),
        target: target
    )

    await keepalive.waitForCompletion()
    try await Task.sleep(for: .milliseconds(5))
    #expect(target.pingCount == 1)
    #expect(target.wasCancelled)
}

@Test func relayWebSocketKeepaliveStopsWhenCancelled() async throws {
    let recorder = KeepalivePingRecorder()
    let keepalive = RelayWebSocketKeepalive(interval: .seconds(1)) {
        await recorder.recordPing()
    } onFailure: {
        await recorder.recordFailure()
    }

    keepalive.cancel()
    await keepalive.waitForCompletion()
    #expect(await recorder.count == 0)
    #expect(await recorder.failureCount == 0)
}

@Test func relayWebSocketKeepaliveCancellationDoesNotCancelAnInFlightHealthyPing() async throws {
    let target = KeepaliveTargetStub(pingDelay: .seconds(1))
    let keepalive = RelayWebSocketKeepalive(
        interval: .milliseconds(1),
        target: target
    )

    try await waitForTargetPings(1, target: target)
    keepalive.cancel()
    await keepalive.waitForCompletion()

    #expect(target.pingCount == 1)
    #expect(!target.wasCancelled)
}

private actor KeepalivePingRecorder {
    private(set) var count = 0
    private(set) var failureCount = 0

    func recordPing() {
        count += 1
    }

    func recordFailure() {
        failureCount += 1
    }
}

private final class KeepaliveTargetStub: RelayWebSocketKeepaliveTarget,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let failsPing: Bool
    private let pingDelay: Duration?
    private var recordedPingCount = 0
    private var cancelled = false

    init(failsPing: Bool = false, pingDelay: Duration? = nil) {
        self.failsPing = failsPing
        self.pingDelay = pingDelay
    }

    var pingCount: Int {
        lock.withLock { recordedPingCount }
    }

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    func ping() async throws {
        lock.withLock { recordedPingCount += 1 }
        if let pingDelay {
            try await Task.sleep(for: pingDelay)
        }
        if failsPing {
            throw KeepaliveTestFailure.pingFailed
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private func waitForTargetPings(
    _ expectedCount: Int,
    target: KeepaliveTargetStub
) async throws {
    for _ in 0 ..< 100 {
        if target.pingCount >= expectedCount {
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw KeepaliveTestFailure.timedOut
}

private func waitForPings(_ expectedCount: Int, recorder: KeepalivePingRecorder) async throws {
    for _ in 0 ..< 100 {
        if await recorder.count >= expectedCount {
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw KeepaliveTestFailure.timedOut
}
