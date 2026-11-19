"""Exercise shutdown entry points without touching VPN services or Wi-Fi."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DisconnectTests(unittest.TestCase):
    def run_disconnect(self, action, stop_result=0, wifi_result=0, cancel_running=False, vpn_state="disconnected"):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            state = fixture / "state"
            runner = (ROOT / "src/run-vpn.zsh").read_text().replace(
                'ASHLEY_VPN_STATE="$HOME/Library/Application Support/Ashley VPN"',
                f'ASHLEY_VPN_STATE="{state}"',
            )
            (fixture / "run-vpn.zsh").write_text(runner)
            (fixture / "terminal-banner.zsh").write_text("")
            (fixture / "gp-processes.sh").write_text((ROOT / "src/gp-processes.sh").read_text())
            (fixture / "installation-id").write_text("test-installation\n")
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
_gp-vpn-current-state() { print -r -- "$TEST_VPN_STATE"; }
_gp-already-stopped() { return 1; }
gp-check-connect-network() { return 0; }
gp-connect() {
  print -r -- waiting >> "$ASHLEY_VPN_STATE/calls"
  if [[ "$TEST_CANCEL_RUNNING" == 1 ]]; then /bin/sleep 20; fi
}
_gp-net-wired-ready() { return 1; }
_gp-net-system-vpn-connected() { return 1; }
_gp-net-interfaces() { print -r -- en0; }
_gp-disconnect-wifi() {
  print -r -- wifi-picker >> "$ASHLEY_VPN_STATE/calls"
  return "$TEST_WIFI_RESULT"
}
"""
            (fixture / "globalprotect-control.zsh").write_text(controls)
            environment = dict(os.environ, TEST_STOP_RESULT=str(stop_result),
                               ASHLEY_VPN_BACKGROUND="0")
            command = ["/bin/zsh", "-f", str(fixture / "run-vpn.zsh")]
            environment["TEST_WIFI_RESULT"] = str(wifi_result)
            environment["TEST_CANCEL_RUNNING"] = str(int(cancel_running))
            environment["TEST_VPN_STATE"] = vpn_state
            if cancel_running:
                with subprocess.Popen(command + [action], env=environment, text=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      start_new_session=True) as worker:
                    try:
                        deadline = time.monotonic() + 5
                        while not (state / "calls").exists():
                            self.assertLess(time.monotonic(), deadline, "VPN worker never started")
                            time.sleep(0.02)
                        token = (state / "operation.owner").read_text().split()[0]
                        signal_result = subprocess.run(command + ["cancel", token], env=environment,
                                                       capture_output=True, text=True, timeout=5)
                        self.assertEqual(signal_result.returncode, 0, signal_result.stderr)
                        stdout, stderr = worker.communicate(timeout=5)
                        result = subprocess.CompletedProcess(command + [action], worker.returncode, stdout, stderr)
                    finally:
                        if worker.poll() is None:
                            worker.kill()
            else:
                result = subprocess.run(command + [action], env=environment, capture_output=True,
                                        text=True, timeout=10)
            calls = (state / "calls").read_text().splitlines()
            self.assertFalse((state / "operation.owner").exists())
            self.assertFalse((state / "operation.input").exists())
            return result, calls

    def test_system_helper_can_load_process_checks_under_posix_sh(self):
        result = subprocess.run(
            ["/bin/sh", "-euc", '. "$1"; _gp_processes', "probe", str(ROOT / "src/gp-processes.sh")],
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_confirmed_exit_stops_without_wifi_selection(self):
        result, calls = self.run_disconnect("disconnect-keep-network")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["stop"])

    def test_regular_disconnect_still_offers_wifi_selection(self):
        result, calls = self.run_disconnect("disconnect")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["stop", "wifi-picker"])

    def test_cancelling_wifi_selection_confirms_globalprotect_stays_stopped(self):
        result, calls = self.run_disconnect("disconnect", wifi_result=130)
        self.assertEqual(result.returncode, 130, result.stderr)
        self.assertEqual(calls, ["stop", "wifi-picker", "stop"])

    def test_toggle_connects_a_running_but_disconnected_client(self):
        result, calls = self.run_disconnect("toggle")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["waiting"])

    def test_toggle_disconnects_a_connected_tunnel(self):
        result, calls = self.run_disconnect("toggle", vpn_state="connected")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["stop", "wifi-picker"])

    def test_menu_cancellation_stops_globalprotect_after_interrupting_connect(self):
        result, calls = self.run_disconnect("connect", cancel_running=True)
        self.assertEqual(result.returncode, 130, result.stderr)
        self.assertEqual(calls, ["waiting", "stop"])

    def test_shutdown_failure_is_preserved_without_wifi_selection(self):
        for action in ["disconnect", "disconnect-keep-network"]:
            with self.subTest(action=action):
                result, calls = self.run_disconnect(action, stop_result=7)
                self.assertEqual(result.returncode, 7, result.stderr)
                self.assertEqual(calls, ["stop"])


if __name__ == "__main__":
    unittest.main()
