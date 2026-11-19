import Network
import NetworkExtension

final class RoutedConnection {
    private let flow: NEAppProxyTCPFlow
    private let upstream: Upstream
    private var connection: NWConnection { upstream.connection }
    private let queue: DispatchQueue
    private let cleanup: () -> Void
    private let request: LocalConnectRequest?
    private var finished = false
    private var ready = false
    private var sentEOF = false
    private var receivedEOF = false

    init(flow: NEAppProxyTCPFlow, upstream: Upstream, queue: DispatchQueue, request: LocalConnectRequest?, cleanup: @escaping () -> Void) {
        self.flow = flow
        self.upstream = upstream
        self.queue = queue
        self.cleanup = cleanup
        self.request = request
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.finished else { return }
            switch state {
            case .ready:
                guard !self.ready else { return }
                Task {
                    do {
                        let pending = try await self.upstream.handshake()
                        self.queue.async { self.open(pending: pending) }
                    } catch { self.queue.async { self.finish(error) } }
                }
            case .failed(let error): self.finish(error)
            case .cancelled: self.finish(POSIXError(.ECANCELED))
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            if let self, !self.ready { self.finish(POSIXError(.ETIMEDOUT)) }
        }
    }

    private func open(pending: Data) {
        guard !finished else { return }
        ready = true
        let begin: (Error?) -> Void = { error in
            self.queue.async {
                guard !self.finished else { return }
                if let error { self.finish(error); return }
                if let bytes = self.request?.pending, !bytes.isEmpty {
                    self.connection.send(content: bytes, completion: .contentProcessed { error in
                        if let error { self.finish(error) } else { self.send() }
                    })
                } else { self.send() }
                if pending.isEmpty { self.receive() }
                else {
                    self.flow.write(pending) { error in
                        self.queue.async { if let error { self.finish(error) } else { self.receive() } }
                    }
                }
            }
        }
        if let request { flow.write(request.reply, withCompletionHandler: begin) }
        else { flow.open(withLocalEndpoint: nil, completionHandler: begin) }
    }

    private func send() {
        guard !finished else { return }
        flow.readData { data, error in
            self.queue.async {
                guard !self.finished else { return }
                if let error { self.finish(error); return }
                let eof = data?.isEmpty != false
                self.connection.send(content: data, contentContext: eof ? .finalMessage : .defaultMessage,
                                     isComplete: true, completion: .contentProcessed { error in
                    if let error { self.finish(error) }
                    else if eof {
                        self.sentEOF = true
                        if self.receivedEOF { self.finish(nil) }
                    } else { self.send() }
                })
            }
        }
    }

    private func receive() {
        guard !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, eof, error in
            let next: (Error?) -> Void = { writeError in
                self.queue.async {
                    guard !self.finished else { return }
                    if let failure = writeError ?? error { self.finish(failure) }
                    else if eof {
                        self.flow.closeWriteWithError(nil)
                        self.receivedEOF = true
                        if self.sentEOF { self.finish(nil) }
                    } else { self.receive() }
                }
            }
            if let data, !data.isEmpty { self.flow.write(data, withCompletionHandler: next) }
            else { next(nil) }
        }
    }

    func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        flow.closeReadWithError(error)
        if !receivedEOF { flow.closeWriteWithError(error) }
        connection.cancel()
        cleanup()
    }
}
