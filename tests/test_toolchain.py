"""Toolchain gates and terminal authorization, with all updater commands stubbed."""
import errno
import json
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ToolchainTests(unittest.TestCase):
    def test_version_requirements(self):
        cases = [
            ("6.2.4", "26.2", True),
            ("6.2.5", "26.2.0", True),
            ("6.3", "26.3", True),
            ("7.0", "27.0", True),
            ("5.8.1", "13.3", False),
            ("6.2.3", "26.2", False),
            ("6.2.4", "26.1", False),
            ("6.2.4", "", False),
            ("unknown", "26.2", False),
        ]
        for swift, sdk, expected in cases:
            with self.subTest(swift=swift, sdk=sdk):
                result = subprocess.run([
                    "/bin/zsh", "-f", "-c",
                    'set -eu; source "$1"; ashley_check_toolchain_versions "$2" "$3"',
                    "test", str(ROOT / "src/check-toolchain.zsh"),
                    f"swift-driver version: 1.2 Apple Swift version {swift} (swiftlang-test)", sdk,
                ], capture_output=True, text=True)
                self.assertEqual(result.returncode == 0, expected, result.stderr)

    def run_installer(self, *, answer="y", mode="", update="success", terminal=True):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            (fixture / "src").mkdir()
            for name in ["install.sh", "src/check-toolchain.zsh", "src/terminal-banner.zsh", "src/Info.plist"]:
                content = (ROOT / name).read_text()
                for tool in ["xcrun", "xcode-select", "sudo", "softwareupdate"]:
                    prefix = "/usr/sbin" if tool == "softwareupdate" else "/usr/bin"
                    content = content.replace(f"{prefix}/{tool}", str(fixture / tool))
                (fixture / name).write_text(content)
            (fixture / "src/check-globalprotect.sh").write_text(
                "check_globalprotect() { print GLOBALPROTECT_CHECK_REACHED; return 1; }\n"
            )
            # No actual software installation, privilege elevation or app writes occur.
            stub = fixture / "stub"
            stub.write_text("#!/usr/bin/env python3\n" + f"CONFIG = {json.dumps(update)}\n" + r'''
import pathlib, sys
root = pathlib.Path(sys.argv[0]).absolute().parent
tool = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / 'calls').open('a') as log:
    log.write(tool + ' ' + ' '.join(args) + '\n')
if tool == 'xcrun':
    updated = (root / 'updated').exists()
    if args == ['swiftc', '--version']:
        print('Apple Swift version ' + ('6.3.3' if updated else '5.8.1') + ' (swiftlang-test)')
    elif args == ['--sdk', 'macosx', '--show-sdk-version']:
        print('26.3' if updated else '13.3')
elif tool == 'xcode-select':
    print('/Applications/Xcode.app/Contents/Developer' if CONFIG == 'full-xcode'
          else '/Library/Developer/CommandLineTools')
elif tool == 'softwareupdate':
    assert args == ['--list'], args
    print('* Label: macOS 26.3-25D11')
    print('* Label: Command Line Tools for Xcode-15.0')
    if CONFIG != 'unavailable':
        print('* Label: Command Line Tools for Xcode-26.2')
        print('* Label: Command Line Tools for Xcode 26.3-26.3')
        print('* Label: Command Line Tools for Xcode 27 beta-27.0')
elif tool == 'sudo':
    assert args == ['--', str(root / 'softwareupdate'), '--install',
                    'Command Line Tools for Xcode 26.3-26.3'], args
    if CONFIG == 'failed':
        sys.exit(1)
    if CONFIG != 'still-old':
        (root / 'updated').touch()
''')
            stub.chmod(0o755)
            for tool in ["xcrun", "xcode-select", "softwareupdate", "sudo"]:
                (fixture / tool).symlink_to(stub)
            argv = ["/bin/zsh", "-f", str(fixture / "install.sh")]
            if mode:
                argv.append(mode)
            environment = dict(os.environ, NO_COLOR="1", TERM="dumb")
            for key in ["DEVELOPER_DIR", "TOOLCHAINS"]:
                environment.pop(key, None)
            if terminal:
                pid, master = pty.fork()
                if pid == 0:
                    # Match curl | bash: stdin is not a terminal; consent uses /dev/tty.
                    os.dup2(os.open(os.devnull, os.O_RDONLY), 0)
                    os.execve(argv[0], argv, environment)
                output = b""
                replied = False
                deadline = time.monotonic() + 15
                try:
                    while True:
                        if time.monotonic() > deadline:
                            os.kill(pid, 9)
                            self.fail("installer did not finish")
                        if not select.select([master], [], [], 0.2)[0]:
                            continue
                        try:
                            chunk = os.read(master, 65536)
                        except OSError as error:
                            if error.errno == errno.EIO:
                                break
                            raise
                        if not chunk:
                            break
                        output += chunk
                        if b"[y/N]" in output and not replied:
                            os.write(master, (answer + "\n").encode())
                            replied = True
                finally:
                    os.close(master)
                    os.waitpid(pid, 0)
                output = output.decode()
            else:
                result = subprocess.run(argv, env=environment, capture_output=True, text=True)
                output = result.stdout + result.stderr
            self.assertNotIn("Traceback", output)
            calls = (fixture / "calls").read_text()
            return output, calls

    def test_authorized_update_rechecks_and_continues(self):
        output, calls = self.run_installer()
        self.assertIn("Swift 6.3.3 / macOS SDK 26.3", output)
        self.assertIn("GLOBALPROTECT_CHECK_REACHED", output)
        self.assertEqual(calls.count("sudo -- "), 1)
        self.assertEqual(calls.count("xcrun swiftc --version"), 2)

    def test_cancel_does_not_install(self):
        output, calls = self.run_installer(answer="n")
        self.assertIn("未授权更新", output)
        self.assertNotIn("sudo ", calls)
        self.assertNotIn("GLOBALPROTECT_CHECK_REACHED", output)

    def test_check_is_read_only(self):
        output, calls = self.run_installer(mode="--check")
        self.assertNotIn("[y/N]", output)
        self.assertNotIn("softwareupdate", calls)
        self.assertNotIn("sudo ", calls)
        self.assertNotIn("GLOBALPROTECT_CHECK_REACHED", output)

    def test_update_failure_or_still_old_stops_installation(self):
        for update in ["failed", "still-old", "unavailable"]:
            with self.subTest(update=update):
                output, calls = self.run_installer(update=update)
                self.assertNotIn("GLOBALPROTECT_CHECK_REACHED", output)
                self.assertIn("安装已停止", output)
                if update == "unavailable":
                    self.assertNotIn("sudo ", calls)

    def test_noninteractive_never_updates(self):
        output, calls = self.run_installer(terminal=False)
        self.assertNotIn("softwareupdate", calls)
        self.assertNotIn("sudo ", calls)
        self.assertNotIn("GLOBALPROTECT_CHECK_REACHED", output)

    def test_full_xcode_needs_manual_update(self):
        output, calls = self.run_installer(update="full-xcode")
        self.assertIn("当前未使用默认 Command Line Tools", output)
        self.assertNotIn("softwareupdate", calls)
        self.assertNotIn("sudo ", calls)
        self.assertNotIn("GLOBALPROTECT_CHECK_REACHED", output)


if __name__ == "__main__":
    unittest.main()
