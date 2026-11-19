import Network
import NetworkExtension

struct LocalConnectRequest {
    let endpoint: Network.NWEndpoint
    let pending: Data
    let reply: Data

    static func http(_ bytes: Data) throws -> LocalConnectRequest? {
        guard let header = bytes.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard header.lowerBound <= 16384,
              let text = String(data: bytes[..<header.lowerBound], encoding: .ascii),
              let first = text.components(separatedBy: "\r\n").first else { throw POSIXError(.EINVAL) }
        let fields = first.split(separator: " ")
        guard fields.count == 3, fields[0] == "CONNECT", ["HTTP/1.0", "HTTP/1.1"].contains(fields[2]),
              let parts = URLComponents(string: "https://" + fields[1]), parts.user == nil, parts.password == nil,
              parts.path.isEmpty, parts.query == nil, parts.fragment == nil, let host = parts.host, !host.isEmpty,
              let number = parts.port, let port = UInt16(exactly: number), port > 0 else { throw POSIXError(.EINVAL) }
        return LocalConnectRequest(endpoint: .hostPort(host: .init(host), port: .init(rawValue: port)!),
                                   pending: bytes[header.upperBound...], reply: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
    }

    static func read(_ flow: NEAppProxyTCPFlow, socks: Bool) async throws -> LocalConnectRequest {
        try await flow.open(withLocalEndpoint: nil)
        var bytes = Data()
        func fill(_ count: Int) async throws {
            while bytes.count < count {
                guard bytes.count <= 16384 else { throw POSIXError(.EMSGSIZE) }
                let chunk: Data? = try await withCheckedThrowingContinuation { continuation in
                    flow.readData { data, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
                    }
                }
                guard let next = chunk, !next.isEmpty else { throw POSIXError(.ECONNRESET) }
                bytes.append(next)
            }
        }
        if !socks {
            while true {
                if let request = try http(bytes) { return request }
                try await fill(bytes.count + 1)
            }
        }
        try await fill(2)
        let end = 2 + Int(bytes[1])
        try await fill(end)
        guard bytes[0] == 5, bytes[2..<end].contains(0) else { throw POSIXError(.EPROTONOSUPPORT) }
        try await flow.write(Data([5, 0]))
        bytes = Data(bytes.dropFirst(end))
        try await fill(5)
        guard bytes[0] == 5, bytes[1] == 1, bytes[2] == 0 else { throw POSIXError(.EINVAL) }
        let addressEnd: Int
        let host: Network.NWEndpoint.Host
        switch bytes[3] {
        case 1:
            addressEnd = 8
            try await fill(addressEnd + 2)
            guard let address = IPv4Address(Data(bytes[4..<addressEnd])) else { throw POSIXError(.EINVAL) }
            host = .ipv4(address)
        case 4:
            addressEnd = 20
            try await fill(addressEnd + 2)
            guard let address = IPv6Address(Data(bytes[4..<addressEnd])) else { throw POSIXError(.EINVAL) }
            host = .ipv6(address)
        case 3:
            addressEnd = 5 + Int(bytes[4])
            try await fill(addressEnd + 2)
            guard let domain = String(data: bytes[5..<addressEnd], encoding: .ascii), !domain.isEmpty else { throw POSIXError(.EINVAL) }
            host = .init(domain)
        default: throw POSIXError(.EINVAL)
        }
        let port = UInt16(bytes[addressEnd]) << 8 | UInt16(bytes[addressEnd + 1])
        guard port > 0 else { throw POSIXError(.EINVAL) }
        return LocalConnectRequest(endpoint: .hostPort(host: host, port: .init(rawValue: port)!),
                                   pending: bytes.dropFirst(addressEnd + 2), reply: Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
    }
}
