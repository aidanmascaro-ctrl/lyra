import Foundation
import Network

/// A one-shot web server on 127.0.0.1 for Google's sign-in redirect: the browser lands here with the code, sees
/// "you can close this tab", and Lyra gets the request's target (`/?state=…&code=…`).
final class LoopbackListener: @unchecked Sendable {
    // Everything below is touched only on `queue`.
    private let listener: NWListener
    private let queue = DispatchQueue(label: "au.aidos.lyra.loopback")
    private var ready: CheckedContinuation<URL, Error>?
    private var waiter: CheckedContinuation<String, Error>?
    private var arrived: String?
    private var stopped = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening on a free port; returns the redirect URL to give Google.
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                ready = continuation
                listener.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
                listener.newConnectionHandler = { [weak self] in self?.handle($0) }
                listener.start(queue: queue)
            }
        }
    }

    /// Waits for the browser to come back from Google.
    func callbackTarget() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let arrived { continuation.resume(returning: arrived) }
                else if stopped { continuation.resume(throwing: CancellationError()) }
                else { waiter = continuation }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            listener.cancel()
            ready?.resume(throwing: CancellationError())
            waiter?.resume(throwing: CancellationError())
            ready = nil
            waiter = nil
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            ready?.resume(returning: URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)")!)
            ready = nil
        case .failed(let error):
            ready?.resume(throwing: error)
            ready = nil
        default: break
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            // "GET /?state=…&code=… HTTP/1.1"
            let words = String(decoding: data ?? Data(), as: UTF8.self).split(separator: " ", maxSplits: 2)
            let target = words.count >= 2 ? String(words[1]) : "/"
            let isCallback = target.contains("code=") || target.contains("error=")
            reply(to: connection, found: isCallback, ok: !target.contains("error="))
            guard isCallback, arrived == nil else { return }  // the browser also asks for a favicon
            arrived = target
            waiter?.resume(returning: target)
            waiter = nil
        }
    }

    private func reply(to connection: NWConnection, found: Bool, ok: Bool) {
        let message = ok ? "Lyra is connected to Google Calendar. You can close this tab." : "Google sign-in didn't finish. You can close this tab and try again from Lyra."
        let body = found ? "<html><body style=\"font: 16px -apple-system; padding: 40px; background: #292929; color: #eee\">\(message)</body></html>" : ""
        let head = "HTTP/1.1 \(found ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
