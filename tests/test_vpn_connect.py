"""Check the connection fallback without opening the client or changing the network."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ConnectTests(unittest.TestCase):
    def wait_for_connection(self, state_function, connect_function):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            controls = (ROOT / "src/globalprotect-control.zsh").read_text()
            start = controls.index("_gp-wait-vpn()")
            end = controls.index("_gp-reset-first-connection()", start)
            # Advance the wait loop without a real delay.
            wait = controls[start:end].replace("/bin/sleep 1", "(( SECONDS += 1 ))")
            (fixture / "wait.zsh").write_text(wait + state_function + connect_function + "\n_gp-wait-vpn 16\n")
            result = subprocess.run(
                ["/bin/zsh", "-f", str(fixture / "wait.zsh")],
                cwd=fixture, capture_output=True, text=True, timeout=5,
            )
            calls = (fixture / "calls").read_text().splitlines() if (fixture / "calls").exists() else []
            return result, calls

    def test_disconnected_client_uses_connect_once_and_checks_tunnel(self):
        result, calls = self.wait_for_connection(
            '_gp-vpn-current-state() { if [[ -f calls ]]; then print connected; else print disconnected; fi }',
            '\n_gp-request-vpn-connect() { print -r -- "$1" >> calls; }',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["prompt"])
        self.assertIn("隧道已建立", result.stdout)

    def test_permission_can_be_granted_during_the_same_attempt(self):
        result, calls = self.wait_for_connection(
            '_gp-vpn-current-state() { if [[ -f submitted ]]; then print connected; else print disconnected; fi }',
            '''
_gp-request-vpn-connect() {
  print -r -- "$1" >> calls
  [[ "$1" != prompt ]] || return 3
  : > submitted
}
''',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["prompt", "check"])

    def test_in_progress_and_unknown_states_do_not_click(self):
        for state in ["auth", "configuration", "tunnel", "verifying", "disconnecting", "failed"]:
            with self.subTest(state=state):
                result, calls = self.wait_for_connection(
                    f'_gp-vpn-current-state() {{ print {state}; }}',
                    '\n_gp-request-vpn-connect() { print -r -- "$1" >> calls; }',
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(calls, [])
        result, calls = self.wait_for_connection(
            '_gp-vpn-current-state() { return 1; }',
            '\n_gp-request-vpn-connect() { print -r -- "$1" >> calls; }',
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
