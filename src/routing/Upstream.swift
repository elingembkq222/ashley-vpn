import Foundation
import Network

struct Upstream {
    let connection: NWConnection
    let proxyScheme: String?
    let target: NWEndpoint

    // The TCP peer is always the selected proxy. Only the CONNECT request names the destination.
    func handshake() async throws -> Data {
        guard let proxyScheme else { return Data() }
        guard case let .hostPort(host, port) = target else { throw POSIXError(.EINVAL) }
        let name = String(describing: host)
        guard !name.isEmpty, name.utf8.allSatisfy({ (33...126).contains($0) }) else { throw POSIXError(.EINVAL) }
        if proxyScheme == "http" {
            let authority = (name.contains(":") && !name.hasPrefix("[") ? "[\(name)]" : name) + ":\(port.rawValue)"
            try await write(Data("CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n\r\n".utf8))
            var response = Data()
            while response.count <= 16384 {
                response.append(try await read(minimum: 1, maximum: 4096))
                if let end = response.range(of: Data("\r\n\r\n".utf8)) {
                    let status = String(decoding: response[..<end.lowerBound], as: UTF8.self)
                        .components(separatedBy: "\r\n")[0].split(separator: " ")
                    guard end.lowerBound <= 16384, status.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(status[0]),
                          let code = Int(status[1]), (200..<300).contains(code) else { throw POSIXError(.ECONNREFUSED) }
                    return Data(response[end.upperBound...])
                }
            }
            throw POSIXError(.EMSGSIZE)
        }
        guard proxyScheme == "socks5h" else { throw POSIXError(.EPROTONOSUPPORT) }
        try await write(Data([5, 1, 0]))
        guard try await exact(2) == Data([5, 0]) else { throw POSIXError(.EACCES) }
        var request = Data([5, 1, 0])
        switch host {
        case .ipv4(let address): request.append(1); request.append(address.rawValue)
        case .ipv6(let address): request.append(4); request.append(address.rawValue)
        case .name(let domain, _):
            guard let count = UInt8(exactly: domain.utf8.count) else { throw POSIXError(.EINVAL) }
            request.append(contentsOf: [3, count]); request.append(contentsOf: domain.utf8)
        @unknown default: throw POSIXError(.EINVAL)
        }
        let number = port.rawValue
        request.append(contentsOf: [UInt8(number >> 8), UInt8(number & 255)])
        try await write(request)
        let reply = try await exact(4)
        guard reply[0] == 5, reply[1] == 0, reply[2] == 0 else { throw POSIXError(.ECONNREFUSED) }
        let addressLength: Int
        switch reply[3] {
        case 1: addressLength = 4
        case 4: addressLength = 16
        case 3: addressLength = Int(try await exact(1)[0])
        default: throw POSIXError(.EINVAL)
        }
        _ = try await exact(addressLength + 2)
        return Data()
    }

    private func write(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func exact(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            result.append(try await read(minimum: 1, maximum: count - result.count))
        }
        return result
    }

    private func read(minimum: Int, maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { bytes, _, _, error in
                if let bytes, !bytes.isEmpty { continuation.resume(returning: bytes) }
                else { continuation.resume(throwing: error ?? .posix(.ECONNRESET)) }
            }
        }
    }
}
