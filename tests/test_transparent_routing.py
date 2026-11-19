import socketserver
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path


class TransparentRoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.build.cleanup)
        tests = Path(__file__).resolve().parent
        src = tests.parent / "src"
        cls.check = Path(cls.build.name) / "route-check"
        subprocess.run(["xcrun", "swiftc", tests / "route-check.swift", src / "CodexProxyStatus.swift",
                        *sorted(p for p in (src / "routing").glob("*.swift") if p.name != "main.swift"),
                        "-o", cls.check], check=True)

    def test_local_proxy_handshake(self):
        subprocess.run([self.check, "parse"], check=True)

    def test_selected_listener_carries_application_bytes(self):
        requests = []

        class Proxy(socketserver.StreamRequestHandler):
            def handle(self):
                self.connection.settimeout(5)
                requests.append(self.rfile.readline().split()[:2])
                while self.rfile.readline() not in (b"", b"\r\n"):
                    pass
                self.wfile.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                if self.rfile.read(4) == b"ping":
                    self.wfile.write(b"pong")

        with socketserver.ThreadingTCPServer(("127.0.0.1", 0), Proxy) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                subprocess.run([self.check, "proxy", f"http://127.0.0.1:{server.server_address[1]}"], check=True, timeout=15)
            finally:
                server.shutdown()
            self.assertEqual(requests, [[b"CONNECT", b"upstream.invalid:443"]])

    def test_rejected_proxy_never_reaches_direct_listener(self):
        attempted = threading.Event()

        class Reject(socketserver.StreamRequestHandler):
            def handle(self):
                if self.rfile.readline().startswith(b"CONNECT "):
                    attempted.set()
                    self.wfile.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")

        with socket.create_server(("127.0.0.1", 0)) as direct, socketserver.ThreadingTCPServer(("127.0.0.1", 0), Reject) as proxy:
            threading.Thread(target=proxy.serve_forever, daemon=True).start()
            try:
                result = subprocess.run([self.check, "proxy", f"http://127.0.0.1:{proxy.server_address[1]}",
                                         "127.0.0.1", str(direct.getsockname()[1])], timeout=15)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(attempted.is_set())
                direct.settimeout(0.15)
                with self.assertRaises(socket.timeout):
                    direct.accept()
            finally:
                proxy.shutdown()

    def test_socks_listener_resolves_target_domain(self):
        requests = []

        class Socks(socketserver.StreamRequestHandler):
            def handle(self):
                self.connection.settimeout(5)
                if self.rfile.read(3) != bytes([5, 1, 0]):
                    return
                self.wfile.write(bytes([5, 0]))
                if self.rfile.read(4) != bytes([5, 1, 0, 3]):
                    return
                name = self.rfile.read(self.rfile.read(1)[0])
                port = int.from_bytes(self.rfile.read(2), "big")
                requests.append((name, port))
                self.wfile.write(bytes([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
                if self.rfile.read(4) == b"ping":
                    self.wfile.write(b"pong")

        with socketserver.ThreadingTCPServer(("127.0.0.1", 0), Socks) as server:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                subprocess.run([self.check, "proxy", f"socks5h://127.0.0.1:{server.server_address[1]}"], check=True, timeout=15)
            finally:
                server.shutdown()
            self.assertEqual(requests, [(b"upstream.invalid", 443)])
