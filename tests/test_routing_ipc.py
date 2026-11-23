import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest


class RoutingIPCTest(unittest.TestCase):
    def test_peer_identity_and_invalid_requests(self):
        src = Path(__file__).resolve().parents[1] / "src"
        with tempfile.TemporaryDirectory(prefix="ipc-", dir="/tmp") as directory:
            root = Path(directory)
            entry = root / "entry.swift"
            entry.write_text('''
import Foundation
@main struct Probe {
    static func main() throws {
        try RoutingIPC.serve(uid: getuid(), path: CommandLine.arguments[1]) { args, peer in
            .init(code: 0, message: "\\(peer):" + args.joined(separator: ","))
        }
        print("ready"); fflush(stdout)
        RunLoop.main.run()
    }
}
''')
            binary = root / "probe"
            subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(entry),
                            str(src / "RoutingIPC.swift"), str(src / "DomainRouting.swift"),
                            str(src / "RoutingAuthorization.swift"), "-o", str(binary)], check=True)
            path = str(root / "socket")
            server = subprocess.Popen([str(binary), path], stdout=subprocess.PIPE, text=True)
            try:
                self.assertEqual(server.stdout.readline().strip(), "ready")
                self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
                for message, code in [(b'["apply","-"]\n', 0), (b'{}\n', 77), (b'x' * 9000 + b'\n', 77)]:
                    with socket.socket(socket.AF_UNIX) as client:
                        client.settimeout(5)
                        client.connect(path)
                        client.sendall(message)
                        response = json.loads(client.makefile("rb").readline())
                        self.assertEqual(response["code"], code)
                        if code == 0:
                            self.assertEqual(response["message"], f"{os.getuid()}:apply,-")
            finally:
                server.terminate()
                server.wait(timeout=5)
                server.stdout.close()
