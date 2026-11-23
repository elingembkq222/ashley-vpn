import Foundation
import Network

final class PACServer {
    private let queue = DispatchQueue(label: "com.ashley.vpn.pac")
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private let port: UInt16
    private let ready: ((UInt16) -> Void)?

    init(port: UInt16 = DomainRouting.pacPort, ready: ((UInt16) -> Void)? = nil) {
        self.port = port
        self.ready = ready
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if case .ready = state, let port = listener?.port { self?.ready?(port.rawValue) }
            if case .failed = state { exit(1) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.clients.count < 32 else { connection.cancel(); return }
            let id = UUID()
            self.clients[id] = connection
            connection.start(queue: self.queue)
            self.receive(connection, id: id, buffer: Data())
            self.queue.asyncAfter(deadline: .now() + 5) { self.finish(id) }
        }
        listener.start(queue: queue)
    }

    private func finish(_ id: UUID) {
        clients.removeValue(forKey: id)?.cancel()
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 8192, error == nil else { self.finish(id); return }
            if let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") {
                let parts = request.components(separatedBy: "\r\n")[0].split(separator: " ")
                let script = parts.count == 3 && parts[0] == "GET"
                    ? DomainRouting.scriptFromPACURL("http://127.0.0.1:\(DomainRouting.pacPort)" + parts[1]) : nil
                let body = Data((script ?? "Not found").utf8)
                let status = script == nil ? "404 Not Found" : "200 OK"
                let headers = "HTTP/1.1 \(status)\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { _ in self.finish(id) })
            } else if complete { self.finish(id) }
            else { self.receive(connection, id: id, buffer: buffer) }
        }
    }
}
