import Foundation
import Network

/// A one-shot web server on this Mac only, for the sign-in redirect: the browser lands here with the code, sees
/// "you can close this tab", and Lyra gets the request's target (`/?state=…&code=…`). Listens on 127.0.0.1 and,
/// when it can, ::1 on the same port, since "localhost" (Microsoft's redirect) may resolve to either.
final class LoopbackListener: @unchecked Sendable {
    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "au.aidos.lyra.loopback")
    private var listeners: [NWListener] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var arrived: String?
    private var stopped = false

    /// Starts listening on a free port; returns it.
    func start() async throws -> UInt16 {
        let port = try await listen(host: .ipv4(.loopback), port: .any)
        if let same = NWEndpoint.Port(rawValue: port) { _ = try? await listen(host: .ipv6(.loopback), port: same) }
        return port
    }

    /// Waits for the browser to come back from the sign-in page.
    func callbackTarget() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let arrived { continuation.resume(returning: arrived) }
                else if stopped { continuation.resume(throwing: CancellationError()) }
                else { waiter = continuation }
            }
        }
    }

    func stop() { queue.async { [self] in finish(CancellationError()) } }

    private func listen(host: NWEndpoint.Host, port: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
        let listener = try NWListener(using: parameters)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !stopped else { return continuation.resume(throwing: CancellationError()) }
                let isFirst = listeners.isEmpty
                listeners.append(listener)
                let ready = Once(continuation)
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: ready.resume(.success(listener.port?.rawValue ?? 0))
                    case .failed(let error):
                        ready.resume(.failure(error))
                        if isFirst { self?.finish(error) }  // the main listener died: stop waiting for the browser
                    case .cancelled: ready.resume(.failure(CancellationError()))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] in self?.handle($0) }
                listener.start(queue: queue)
            }
        }
    }

    /// On `queue`.
    private func finish(_ error: Error) {
        stopped = true
        listeners.forEach { $0.cancel() }
        waiter?.resume(throwing: error)
        waiter = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            // "GET /?state=…&code=… HTTP/1.1"
            let words = String(decoding: data ?? Data(), as: UTF8.self).split(separator: " ", maxSplits: 2)
            let target = words.count >= 2 ? String(words[1]) : "/"
            let isCallback = target.contains("code=") || target.contains("error=")
            Self.reply(to: connection, found: isCallback, ok: !target.contains("error="))
            guard isCallback, arrived == nil else { return }  // the browser also asks for a favicon
            arrived = target
            waiter?.resume(returning: target)
            waiter = nil
        }
    }

    private static func reply(to connection: NWConnection, found: Bool, ok: Bool) {
        let message = ok ? "Lyra is connected to your calendar. You can close this tab."
            : "Sign-in didn't finish. You can close this tab and try again from Lyra."
        let body = found ? "<html><body style=\"font: 16px -apple-system; padding: 40px; background: #292929; color: #eee\">\(message)</body></html>" : ""
        let head = "HTTP/1.1 \(found ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Resumes a continuation the first time only (a listener reports several states). Used on one queue.
private final class Once: @unchecked Sendable {
    private var continuation: CheckedContinuation<UInt16, Error>?

    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }

    func resume(_ result: Result<UInt16, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
