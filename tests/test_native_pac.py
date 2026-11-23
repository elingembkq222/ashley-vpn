from pathlib import Path
import subprocess
import tempfile
import unittest
import urllib.request


class NativePACTest(unittest.TestCase):
    def test_http_pac_is_loaded_by_native_network_stack(self):
        src = Path(__file__).resolve().parents[1] / "src"
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            entry = directory / "probe.swift"
            entry.write_text('''
import Foundation
import CFNetwork
@main struct Probe {
    static func main() throws {
        let script = try DomainRouting.script(for: URL(string: "http://127.0.0.1:8890")!)
        let server = PACServer(port: 0) { port in
            print("\\(port) " + DomainRouting.pacURL(for: script)); fflush(stdout)
        }
        try server.start()
        withExtendedLifetime(server) { RunLoop.main.run() }
    }
}
''')
            binary = directory / "probe"
            subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(entry),
                            str(src / "PACServer.swift"), str(src / "DomainRouting.swift"),
                            str(src / "RoutingAuthorization.swift"), "-o", str(binary)], check=True)
            process = subprocess.Popen([str(binary)], stdout=subprocess.PIPE, text=True)
            try:
                port, url = process.stdout.readline().strip().split(" ", 1)
                url = url.replace(":18946/", f":{port}/")
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                with opener.open(url, timeout=5) as response:
                    self.assertEqual(response.status, 200)
                    self.assertIn(b"FindProxyForURL", response.read())
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    opener.open(f"http://127.0.0.1:{port}/proxy/invalid.pac", timeout=5)
                self.assertEqual(failure.exception.code, 404)
                failure.exception.close()
                native = r'''
import Foundation
import CFNetwork
var finished = false
var ctx = CFStreamClientContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
let source = CFNetworkExecuteProxyAutoConfigurationURL(URL(string: CommandLine.arguments[1])! as CFURL,
    URL(string: "https://chatgpt.com/backend-api/settings/user")! as CFURL, { _, proxies, error in
        precondition(error == nil, String(describing: error))
        let routes = proxies as! [[String: Any]]
        precondition(routes.first?[kCFProxyHostNameKey as String] as? String == "127.0.0.1")
        precondition(routes.first?[kCFProxyPortNumberKey as String] as? Int == 8890)
        finished = true
        CFRunLoopStop(CFRunLoopGetCurrent())
    }, &ctx)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
CFRunLoopRunInMode(.defaultMode, 8, false)
precondition(finished, "native PAC timed out")
'''
                subprocess.run(["xcrun", "swift", "-", url], input=native, text=True, timeout=15, check=True)
            finally:
                process.terminate()
                process.wait(timeout=5)
                process.stdout.close()
