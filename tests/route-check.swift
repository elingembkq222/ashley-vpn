import Foundation
import Network
import Security

@main
enum RouteCheck {
    static func main() throws {
        let arguments = CommandLine.arguments
        switch arguments[1] {
        case "identity":
            let attributes = [kSecGuestAttributePid as String: Int(arguments[2])!] as CFDictionary
            var code: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { exit(2) }
            print(CodexProvider.isVerifiedRuntime(code))
        case "parse":
            let partial = try LocalConnectRequest.http(Data("CONNECT upstream.invalid:443 HTTP/1.1\r\n".utf8))
            precondition(partial == nil)
            let bytes = Data("CONNECT upstream.invalid:443 HTTP/1.1\r\nHost: upstream.invalid\r\n\r\nclient-data".utf8)
            let parsed = try LocalConnectRequest.http(bytes)!
            precondition(parsed.pending == Data("client-data".utf8))
            precondition(parsed.endpoint == .hostPort(host: "upstream.invalid", port: 443))
            for malformed in ["GET / HTTP/1.1", "CONNECT example:65536 HTTP/1.1", "CONNECT user@host:443 HTTP/1.1"] {
                do {
                    _ = try LocalConnectRequest.http(Data((malformed + "\r\n\r\n").utf8))
                    exit(3)
                } catch {}
            }
        case "proxy":
            let url = URL(string: arguments[2])!
            guard let route = CodexProxyStatus.localProxyRoute(url) else { exit(4) }
            let provider = CodexProvider()
            let wrongOwner = CodexProxyStatus.Route(id: "proxy:wrong", name: "wrong", kind: route.kind)
            let target = arguments.count > 3 ? arguments[3] : "upstream.invalid"
            let port = arguments.count > 4 ? UInt16(arguments[4])! : 443
            let destination = NWEndpoint.hostPort(host: .init(target), port: .init(rawValue: port)!)
            precondition(provider.upstream(to: destination, using: .init(wrongOwner)) == nil)
            guard let upstream = provider.upstream(to: destination, using: .init(route)) else { exit(5) }
            let connection = upstream.connection
            let queue = DispatchQueue(label: "route-test")
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task {
                        do { _ = try await upstream.handshake() } catch { exit(8) }
                        connection.send(content: Data("ping".utf8), completion: .contentProcessed { error in
                            if error != nil { exit(6) }
                        })
                        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, _ in
                            exit(data == Data("pong".utf8) ? 0 : 7)
                        }
                    }
                case .failed: exit(8)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 8) { exit(9) }
            dispatchMain()
        default: exit(1)
        }
    }

}
