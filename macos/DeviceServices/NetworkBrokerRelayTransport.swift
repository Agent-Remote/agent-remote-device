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

public final class URLSessionNetworkBrokerRelayWebSocket: NetworkBrokerRelayWebSocket,
    @unchecked Sendable
{
    public static let maximumFrameBytes = 4 * 1_024 * 1_024

    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private let delegate: RelaySessionDelegate

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
        task = session.webSocketTask(with: request)
        task.resume()
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
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
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
