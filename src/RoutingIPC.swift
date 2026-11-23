import Foundation
import Darwin

enum RoutingIPC {
    static let path = "/var/run/ashley-vpn-routing.sock"
    struct Reply: Codable { let code: Int32; let message: String }

    static func address(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        guard path.utf8CString.count <= MemoryLayout.size(ofValue: address.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            for (index, byte) in path.utf8CString.enumerated() { target[index] = UInt8(bitPattern: byte) }
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func timeout(_ fd: Int32) {
        var value = timeval(tv_sec: 20, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    static func line(_ fd: Int32) throws -> Data {
        var result = Data(), bytes = [UInt8](repeating: 0, count: 1024)
        while result.count < 8192 {
            let count = read(fd, &bytes, bytes.count)
            guard count > 0 else { throw DomainRouting.Failure("网络组件未响应") }
            result.append(contentsOf: bytes.prefix(count))
            if let end = result.firstIndex(of: 10) { return result.prefix(upTo: end) }
        }
        throw DomainRouting.Failure("网络组件请求过长")
    }

    static func send<T: Encodable>(_ value: T, fd: Int32) throws {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw DomainRouting.Failure("无法联系网络组件") }
                offset += count
            }
        }
    }

    static func request(_ args: [String], path: String = path) throws -> Reply {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DomainRouting.Failure("无法打开网络组件连接") }
        defer { close(fd) }
        timeout(fd)
        guard address(path: path, { connect(fd, $0, $1) }) == 0 else { throw DomainRouting.Failure("网络组件尚未安装") }
        try send(args, fd: fd)
        return try JSONDecoder().decode(Reply.self, from: line(fd))
    }

    static func serve(uid: uid_t, path: String = path, handler: @escaping ([String], uid_t) -> Reply) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DomainRouting.Failure("无法打开网络组件服务") }
        unlink(path)
        guard address(path: path, { bind(fd, $0, $1) }) == 0, chown(path, uid, getegid()) == 0,
              chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd); throw DomainRouting.Failure("无法启动网络组件服务")
        }
        DispatchQueue.global(qos: .utility).async {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                defer { close(client) }
                timeout(client)
                var owner: uid_t = 0, group: gid_t = 0
                guard getpeereid(client, &owner, &group) == 0, owner == uid else { continue }
                do {
                    let args = try JSONDecoder().decode([String].self, from: line(client))
                    try send(handler(args, owner), fd: client)
                } catch { try? send(Reply(code: 77, message: error.localizedDescription), fd: client) }
            }
        }
    }
}
