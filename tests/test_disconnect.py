"""Exercise shutdown entry points without touching VPN services or Wi-Fi."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DisconnectTests(unittest.TestCase):
    def run_disconnect(self, action, stop_result=0):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            state = fixture / "state"
            runner = (ROOT / "src/run-vpn.zsh").read_text().replace(
                'ASHLEY_VPN_STATE="$HOME/Library/Application Support/Ashley VPN"',
                f'ASHLEY_VPN_STATE="{state}"',
            )
            (fixture / "run-vpn.zsh").write_text(runner)
            (fixture / "terminal-banner.zsh").write_text("")
            (fixture / "check-globalprotect.sh").write_text(
                "check_globalprotect() { return 0; }\n"
            )
            # Use the real disconnect flow; replace only system operations/input.
            controls = (ROOT / "src/globalprotect-control.zsh").read_text()
            controls += """
gp-stop() {
  print -r -- stop >> "$ASHLEY_VPN_STATE/calls"
  return "$TEST_STOP_RESULT"
}
_gp-net-wired-ready() { return 1; }
_gp-net-system-vpn-connected() { return 1; }
_gp-net-interfaces() { print -r -- en0; }
_gp-disconnect-wifi() {
  print -r -- wifi-picker >> "$ASHLEY_VPN_STATE/calls"
}
"""
            (fixture / "globalprotect-control.zsh").write_text(controls)
            environment = dict(os.environ, TEST_STOP_RESULT=str(stop_result),
                               ASHLEY_VPN_BACKGROUND="0")
            result = subprocess.run(
                ["/bin/zsh", "-f", str(fixture / "run-vpn.zsh"), action],
                env=environment, capture_output=True, text=True, timeout=10,
            )
            calls = (state / "calls").read_text().splitlines()
            self.assertFalse((state / "operation.owner").exists())
            self.assertFalse((state / "operation.input").exists())
            return result, calls

    def test_confirmed_exit_stops_without_wifi_selection(self):
        result, calls = self.run_disconnect("disconnect-keep-network")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["stop"])

    def test_regular_disconnect_still_offers_wifi_selection(self):
        result, calls = self.run_disconnect("disconnect")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["stop", "wifi-picker"])

    def test_shutdown_failure_is_preserved_without_wifi_selection(self):
        for action in ["disconnect", "disconnect-keep-network"]:
            with self.subTest(action=action):
                result, calls = self.run_disconnect(action, stop_result=7)
                self.assertEqual(result.returncode, 7, result.stderr)
                self.assertEqual(calls, ["stop"])


if __name__ == "__main__":
    unittest.main()
