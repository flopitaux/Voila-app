import Foundation
import Network

/// One-shot HTTP server bound to 127.0.0.1 that captures the OAuth redirect
/// (Google's recommended flow for desktop apps).
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Voila.loopback")
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private var callbackContinuation: CheckedContinuation<[String: String], Error>?
    private var pendingResult: Result<[String: String], Error>?
    private var finished = false

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
    }

    /// Starts listening and returns the port the OS assigned.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else { return cont.resume(throwing: CancellationError()) }
                self.readyContinuation = cont
                self.listener.stateUpdateHandler = { [weak self] state in self?.handle(state) }
                self.listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
                self.listener.start(queue: self.queue)
            }
        }
    }

    /// Waits for the browser to hit the redirect URI; returns its query parameters.
    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let result = self.pendingResult {
                    self.pendingResult = nil
                    cont.resume(with: result)
                } else {
                    self.callbackContinuation = cont
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.finish(.failure(CancellationError()))
            self.listener.cancel()
        }
    }

    // MARK: - Private (all on `queue`)

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener.port?.rawValue {
                readyContinuation?.resume(returning: port)
                readyContinuation = nil
            }
        case .failed(let error):
            readyContinuation?.resume(throwing: error)
            readyContinuation = nil
            finish(.failure(error))
        default:
            break
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard !finished else { return }
        finished = true
        if let cont = callbackContinuation {
            callbackContinuation = nil
            cont.resume(with: result)
        } else {
            pendingResult = result
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let requestLine = request.components(separatedBy: "\r\n").first ?? ""
            let parts = requestLine.split(separator: " ")
            var params: [String: String] = [:]
            if parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) {
                for item in comps.queryItems ?? [] { params[item.name] = item.value ?? "" }
            }
            let isCallback = params["code"] != nil || params["error"] != nil
            let body = isCallback ? Self.page(success: params["error"] == nil) : "Not found"
            let response = """
            HTTP/1.1 \(isCallback ? "200 OK" : "404 Not Found")\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if isCallback { self.finish(.success(params)) }
        }
    }

    private static func page(success: Bool) -> String {
        let title = success ? "You're all set ✨" : "Sign-in was cancelled"
        let sub = success ? "Voilà is connected to Google Tasks. You can close this tab."
                          : "Head back to Voilà to try again."
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Voilà</title>
        <style>
        body{margin:0;height:100vh;display:grid;place-items:center;font-family:-apple-system,system-ui;
        background:linear-gradient(135deg,#8B5CF6,#EC4899);color:#fff}
        .card{background:rgba(255,255,255,.16);backdrop-filter:blur(20px);padding:48px 56px;border-radius:28px;
        text-align:center;box-shadow:0 20px 60px rgba(0,0,0,.2)}
        h1{margin:0 0 8px;font-size:32px}p{margin:0;opacity:.9;font-size:16px}
        </style></head><body><div class="card"><h1>\(title)</h1><p>\(sub)</p></div></body></html>
        """
    }
}
