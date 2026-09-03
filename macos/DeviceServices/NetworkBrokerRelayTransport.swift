import Foundation

public enum NetworkBrokerRelayTransportFailure: Error, Equatable, Sendable {
    case invalidRequest
    case invalidMessage
    case frameTooLarge
    case disconnected
}

public protocol NetworkBrokerRelayWebSocket: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func cancel()
}

protocol RelayWebSocketKeepaliveTarget: Sendable {
    func ping() async throws
    func cancel()
}

public final class URLSessionNetworkBrokerRelayWebSocket: NetworkBrokerRelayWebSocket,
    @unchecked Sendable
{
    public static let maximumFrameBytes = 4 * 1_024 * 1_024
    static let keepaliveInterval: Duration = .seconds(20)

    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let delegate: RelaySessionDelegate
    private let keepalive: RelayWebSocketKeepalive

    public init(request: URLRequest) throws {
        guard request.url?.scheme == "wss",
              request.url?.host?.isEmpty == false,
              request.url?.query == nil,
              request.url?.fragment == nil,
              request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
        else {
            throw NetworkBrokerRelayTransportFailure.invalidRequest
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 15 * 60
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        configuration.tlsMaximumSupportedProtocolVersion = .TLSv13
        let delegate = RelaySessionDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        self.delegate = delegate
        self.session = session
        let webSocketTask = session.webSocketTask(with: request)
        task = webSocketTask
        webSocketTask.resume()
        keepalive = RelayWebSocketKeepalive(
            interval: Self.keepaliveInterval,
            target: URLSessionRelayWebSocketKeepaliveTarget(task: webSocketTask)
        )
    }

    deinit {
        keepalive.cancel()
    }

    public func send(_ data: Data) async throws {
        guard !data.isEmpty, data.count <= Self.maximumFrameBytes else {
            throw NetworkBrokerRelayTransportFailure.frameTooLarge
        }
        try await task.send(.data(data))
    }

    public func receive() async throws -> Data {
        let message = try await task.receive()
        guard case let .data(data) = message else {
            throw NetworkBrokerRelayTransportFailure.invalidMessage
        }
        guard !data.isEmpty, data.count <= Self.maximumFrameBytes else {
            throw NetworkBrokerRelayTransportFailure.frameTooLarge
        }
        return data
    }

    public func cancel() {
        keepalive.cancel()
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

final class RelayWebSocketKeepalive: @unchecked Sendable {
    private let task: Task<Void, Never>

    convenience init(
        interval: Duration,
        target: any RelayWebSocketKeepaliveTarget
    ) {
        self.init(
            interval: interval,
            ping: { try await target.ping() },
            onFailure: { target.cancel() }
        )
    }

    init(
        interval: Duration,
        ping: @escaping @Sendable () async throws -> Void,
        onFailure: @escaping @Sendable () async -> Void
    ) {
        task = Task {
            do {
                try await Self.run(interval: interval, ping: ping)
            } catch {
                if !Task.isCancelled {
                    await onFailure()
                }
            }
        }
    }

    deinit {
        task.cancel()
    }

    func cancel() {
        task.cancel()
    }

    func waitForCompletion() async {
        await task.value
    }

    private static func run(
        interval: Duration,
        ping: @escaping @Sendable () async throws -> Void
    ) async throws {
        while true {
            try await Task.sleep(for: interval)
            try Task.checkCancellation()
            try await ping()
        }
    }
}

private final class URLSessionRelayWebSocketKeepaliveTarget:
    RelayWebSocketKeepaliveTarget,
    @unchecked Sendable
{
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

private final class RelaySessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
