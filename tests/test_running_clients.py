import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


class RunningClientTests(unittest.TestCase):
    def test_classifies_running_apps_without_system_proxy_settings(self):
        source = Path(__file__).resolve().parents[1] / "src/CodexProxyStatus.swift"
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Example.app"
            extension = app / "Contents/PlugIns/Packet.appex/Contents"
            extension.mkdir(parents=True)
            (extension / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "test.example.packet",
                "NSExtension": {"NSExtensionPointIdentifier": "com.apple.networkextension.packet-tunnel"},
            }))
            checks = """
let tunnel = URL(fileURLWithPath: CommandLine.arguments[1])
let plain = tunnel.deletingLastPathComponent().appendingPathComponent("Plain.app")
func discover(_ identifier: String, _ name: String, _ url: URL) -> CodexProxyStatus.Route? {
    CodexProxyStatus.runningClient(identifier: identifier, name: name, url: url)
}
let client = discover("com.libcyber.pirate", "LibCyber Desktop", plain)!
let endpoints = CodexProxyStatus.libCyberProxyURLs("  port: 443\\nport: 8890 # local\\nsocks-port: 8891\\nmixed-port: 65536")
precondition(endpoints.map { $0.absoluteString } == ["http://127.0.0.1:8890", "socks5h://127.0.0.1:8891"])
precondition(client.kind == .runningClient(supportsSystemProxy: true))
precondition(CodexProxyStatus.Selection(client).id == "proxy:com.libcyber.pirate")
precondition(discover("test.example", "Example", tunnel)?.kind == .runningClient(supportsSystemProxy: false))
precondition(discover("test.plain", "Example", plain) == nil)
precondition(discover("com.ashley.vpn.companion", "Ashley VPN", plain) == nil)
precondition(discover("com.paloaltonetworks.GlobalProtect", "GlobalProtect", tunnel) == nil)
"""
            subprocess.run(["xcrun", "swift", "-", str(app)], input=source.read_text() + checks,
                           text=True, check=True, timeout=60)
