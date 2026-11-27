"""Exercise authorization recovery with fake helpers; never prompt or change VPN state."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]


class AuthorizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="ashley-auth-")
        cls.addClassCleanup(cls.build.cleanup)
        root = Path(cls.build.name)
        cls.helper = root / "helper"
        cls.helper.write_text('''#!/bin/sh
if [ "$1" = check ]; then [ -f "$TEST_STATE/ready" ]; exit $?; fi
echo "$1" >> "$TEST_STATE/calls"
''')
        cls.helper.chmod(0o755)
        prompt = root / "prompt"
        prompt.write_text('''#!/bin/sh
echo authorize >> "$TEST_STATE/calls"
if [ "${TEST_AUTH_RESULT:-0}" != 0 ]; then echo 'User canceled (-128)' >&2; exit 1; fi
[ "${TEST_READY:-1}" = 0 ] || touch "$TEST_STATE/ready"
exit 0
''')
        prompt.chmod(0o755)
        suite = "test.ashley.authorization." + str(uuid.uuid4())
        source = (ROOT / "src/RoutingAuthorization.swift").read_text()
        source = source.replace('"/Library/PrivilegedHelperTools/com.ashley.vpn.routing"', f'"{cls.helper}"')
        source = source.replace('"/usr/bin/osascript"', f'"{prompt}"')
        source = source.replace(
            'Bundle.main.url(forResource: "setup-routing-authorization", withExtension: "sh")',
            f'Optional(URL(fileURLWithPath: "{root}/installer"))',
        )
        source = source.replace("UserDefaults.standard", f'UserDefaults(suiteName: "{suite}")!')
        source = source.replace("0..<50", "0..<2")
        (root / "Authorization.swift").write_text(source)
        (root / "Probe.swift").write_text('''
import Foundation
@main struct Probe {
    static func main() {
        let defaults = UserDefaults(suiteName: "SUITE")!
        defaults.removePersistentDomain(forName: "SUITE")
        defer { defaults.removePersistentDomain(forName: "SUITE") }
        let mode = CommandLine.arguments[1]
        if mode == "retry" || mode == "automatic" {
            defaults.set(true, forKey: "routingAuthorizationAttempted.unknown")
        }
        func attempt(_ retry: Bool) {
            do { try RoutingAuthorization.apply("script", retryAuthorization: retry); print("success") }
            catch { print("failure: " + error.localizedDescription.replacingOccurrences(of: "\\n", with: " ")) }
        }
        if mode == "cancel-retry" {
            setenv("TEST_AUTH_RESULT", "1", 1)
            attempt(true)
            attempt(false)
            setenv("TEST_AUTH_RESULT", "0", 1)
            attempt(true)
        } else if mode == "remove" {
            do { try RoutingAuthorization.apply(nil); print("success") }
            catch { print("failure: " + error.localizedDescription) }
        } else { attempt(mode != "automatic") }
    }
}
'''.replace("SUITE", suite))
        cls.binary = root / "probe"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(root / "Probe.swift"),
                        str(root / "Authorization.swift"), str(ROOT / "src/DomainRouting.swift"),
                        "-o", str(cls.binary)], check=True)

    def run_authorization(self, mode, ready=False, becomes_ready=True):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory)
            if ready:
                (state / "ready").touch()
            result = subprocess.run([self.binary, mode], capture_output=True, text=True, timeout=10,
                                    env=dict(os.environ, TEST_STATE=directory,
                                             TEST_READY=str(int(becomes_ready))))
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = (state / "calls").read_text().splitlines() if (state / "calls").exists() else []
            return result.stdout.splitlines(), calls

    def test_valid_authorization_does_not_prompt(self):
        output, calls = self.run_authorization("retry", ready=True)
        self.assertEqual(output, ["success"])
        self.assertEqual(calls, ["apply"])

    def test_manual_retry_bypasses_previous_failed_attempt_and_resumes(self):
        output, calls = self.run_authorization("retry")
        self.assertEqual(output, ["success"])
        self.assertEqual(calls, ["authorize", "apply"])

    def test_background_does_not_repeat_failed_authorization(self):
        output, calls = self.run_authorization("automatic")
        self.assertTrue(output[0].startswith("failure: "))
        self.assertEqual(calls, [])

    def test_cancel_stops_operation_and_next_manual_attempt_can_retry(self):
        output, calls = self.run_authorization("cancel-retry")
        self.assertTrue(output[0].startswith("failure: "))
        self.assertTrue(output[1].startswith("failure: "))
        self.assertEqual(output[2], "success")
        self.assertEqual(calls, ["authorize", "authorize", "apply"])

    def test_installer_success_requires_helper_readiness(self):
        output, calls = self.run_authorization("retry", becomes_ready=False)
        self.assertTrue(output[0].startswith("failure: "))
        self.assertEqual(calls, ["authorize"])

    def test_removing_absent_route_does_not_request_authorization(self):
        output, calls = self.run_authorization("remove")
        self.assertEqual(output, ["success"])
        self.assertEqual(calls, [])


class VPNAuthorizationTests(unittest.TestCase):
    def run_control(self, operation, ready=False, authorization_result=0, becomes_ready=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            resources = root / "Contents/Resources"
            macos = root / "Contents/MacOS"
            resources.mkdir(parents=True)
            macos.mkdir()
            (resources / "routing-service").touch()
            if ready:
                (root / "ready").touch()
            helper = root / "helper"
            helper.write_text('''#!/bin/sh
if [ "$1" = check ]; then [ -f "$TEST_STATE/ready" ]; exit $?; fi
echo "$1" >> "$TEST_STATE/calls"
''')
            helper.chmod(0o755)
            executable = macos / "ashley-vpn-menu"
            executable.write_text('''#!/bin/sh
echo "$1" >> "$TEST_STATE/calls"
[ "$TEST_AUTH_RESULT" = 0 ] || exit "$TEST_AUTH_RESULT"
[ "$TEST_READY" = 0 ] || touch "$TEST_STATE/ready"
exit 0
''')
            executable.chmod(0o755)
            controls = (ROOT / "src/globalprotect-control.zsh").read_text()
            controls = controls.replace("/Library/PrivilegedHelperTools/com.ashley.vpn.routing", str(helper))
            # All launchctl/pgrep operations are intercepted, including absolute paths.
            controls = controls.replace("/bin/launchctl", "fake_launchctl").replace("/usr/bin/pgrep", "fake_pgrep")
            (root / "controls.zsh").write_text(controls)
            script = '''
source "$TEST_STATE/controls.zsh"
_gp-gui-progress() { :; }
_gp-already-stopped() { [[ "$TEST_OPERATION" == already-stopped ]]; }
_gp-launchctl() { print user-service >> "$TEST_STATE/calls"; }
_gp-start-service() { print start-user-service >> "$TEST_STATE/calls"; }
fake_launchctl() {
  [[ "$1" == print && "$2" == system/com.paloaltonetworks.gp.pangpsd ]]
}
fake_pgrep() { return 0; }
case "$TEST_OPERATION" in
  start) gp-start ;;
  stop) _gp-stop-system-service system/com.paloaltonetworks.gp.pangpsd ;;
  cancel-stop|already-stopped) gp-stop ;;
esac
'''
            result = subprocess.run(["/bin/zsh", "-fc", script], capture_output=True, text=True,
                                    timeout=5, env=dict(os.environ, TEST_STATE=directory,
                                    ASHLEY_VPN_RESOURCES=str(resources), ASHLEY_VPN_BACKGROUND="1",
                                    TEST_AUTH_RESULT=str(authorization_result),
                                    TEST_READY=str(int(becomes_ready)), TEST_OPERATION=operation))
            calls = (root / "calls").read_text().splitlines() if (root / "calls").exists() else []
            return result, calls

    def test_missing_authorization_can_be_repaired_before_stopping_system_service(self):
        result, calls = self.run_control("stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["--authorize-routing", "disable", "bootout"])

    def test_start_can_authorize_and_continue_starting_client(self):
        result, calls = self.run_control("start")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["--authorize-routing", "start-system", "start-user-service"])

    def test_existing_authorization_stops_without_prompt(self):
        result, calls = self.run_control("stop", ready=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["disable", "bootout"])

    def test_cancelling_authorization_does_not_stop_client_or_repeat_prompt(self):
        result, calls = self.run_control("cancel-stop", authorization_result=77)
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertEqual(calls, ["--authorize-routing"])

    def test_helper_still_unavailable_stops_without_repeated_prompts(self):
        result, calls = self.run_control("stop", becomes_ready=False)
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertEqual(calls, ["--authorize-routing"])

    def test_already_stopped_does_not_request_authorization(self):
        result, calls = self.run_control("already-stopped")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
