"""Exercise real Security ACL objects in memory; never touch a keychain."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class KeychainACLTests(unittest.TestCase):
    def test_independent_signing_rules_are_checked_and_repaired(self):
        source = (ROOT / "src/globalprotect-keychain.swift").read_text().split("let args = CommandLine.arguments")[0]
        probe = r'''
func require(_ success: Bool, _ message: String) {
    if !success { fatalError(message) }
}
let paths = ["/usr/bin/true", "/usr/bin/false"]
let apps: [SigningApplication] = paths.map { path in
    var app: SecTrustedApplication?
    require(SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, "trusted app")
    return (path, app!)
}
var result: SecAccess?
let group = trustedIdentityExportGroup()!
require(SecAccessCreate("ACL regression" as CFString,
    (apps.map(\.trusted) + [group]) as CFArray, &result) == errSecSuccess, "create access")
let access = result!
require(PrivateKeyRules(access)!.missingApplications(apps)!.allSatisfy { $0.isEmpty }, "general is complete")
func addRule(_ actions: [String], _ apps: [SecTrustedApplication], _ prompt: SecKeychainPromptSelector = []) -> SecACL {
    var acl: SecACL?
    require(SecACLCreateWithSimpleContents(access, apps as CFArray, "signing" as CFString,
        prompt, &acl) == errSecSuccess, "create rule")
    require(SecACLUpdateAuthorizations(acl!, actions as CFArray) == errSecSuccess, "set operations")
    return acl!
}
// Reproduce the exact regression: general is complete, a separate sign rule lacks PanGPS.
let sign = addRule([kSecACLAuthorizationSign as String], [apps[0].trusted])
var rules = PrivateKeyRules(access)!
require(rules.all.count == 2, "independent sign rule must be included")
let missing = rules.missingApplications(apps)!
require(missing.flatMap { $0 }.map(\.path) == [paths[1]], "detect missing signing app")
for (rule, absent) in zip(rules.all, missing) where !absent.isEmpty {
    require(rule.add(absent, identityExport: nil), "repair")
}
rules = PrivateKeyRules(access)!
require(rules.missingApplications(apps)!.allSatisfy { $0.isEmpty }, "repair must pass recheck")
require(rules.general.hasIdentityExportGroup, "preserve export group")
require(Set(SecACLCopyAuthorizations(sign) as! [String]) == [kSecACLAuthorizationSign as String], "preserve operations")
require(PrivateKeyRule(sign)!.applications.count == 2, "no duplicate app")
// Multiple independent signing entries and password policy must remain visible.
let another = addRule([kSecACLAuthorizationSign as String], [], .requirePassphase)
rules = PrivateKeyRules(access)!
require(rules.all.count == 3, "check all signing rules")
require(rules.missingApplications(apps)!.flatMap { $0 }.count == 2, "empty signing list")
let anotherRule = PrivateKeyRule(another)!
require(anotherRule.add(apps, identityExport: nil), "repair extra rule")
require(PrivateKeyRule(another)!.prompt == .requirePassphase, "preserve password policy")
require(PrivateKeyRules(access)!.missingApplications(apps)!.allSatisfy { $0.isEmpty }, "idempotent check")
// An unexpected signing layout must never produce a false success or broader grants.
_ = addRule([kSecACLAuthorizationSign as String, kSecACLAuthorizationDecrypt as String], [])
require(PrivateKeyRules(access) == nil, "unknown signing layout must fail closed")
print("ACL regression passed")
'''
        with tempfile.TemporaryDirectory() as directory:
            entry = Path(directory) / "probe.swift"
            binary = Path(directory) / "probe"
            entry.write_text(source + "\ndo {\n" + probe + "\n}\n")
            build = subprocess.run(["xcrun", "swiftc", str(entry), "-o", str(binary)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("ACL regression passed", result.stdout)


class InstallerKeychainTests(unittest.TestCase):
    def test_installer_repairs_missing_grants_and_verifies_as_current_user(self):
        installer = (ROOT / "install.sh").read_text()
        start = installer.index("repair_certificate_access() {")
        end = installer.index("\ncheck_existing_installation()", start)
        function = installer[start:end].replace("/usr/bin/sudo", "test_sudo")
        for scenario in ["missing", "complete", "verify-failed"]:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                directory = Path(directory)
                checker = directory / "globalprotect-keychain"
                checker.write_text("""#!/bin/zsh -f
print -r -- "$*" >> calls
case "$1" in
  --check)
    if [[ "$SCENARIO" == complete ]]; then
      print '集团 VPN 私钥访问权限已齐全。'
    else
      print '缺少私钥访问权限：PanGPS' >&2
      print -r -- "$FINGERPRINT"
      exit 3
    fi ;;
  --repair) [[ "$2" == "$FINGERPRINT" ]] || exit 2; print repaired ;;
  --verify) [[ "$SCENARIO" != verify-failed ]] || exit 1; print verified ;;
  *) exit 2 ;;
esac
""")
                checker.chmod(0o755)
                harness = directory / "install-test.zsh"
                harness.write_text("""#!/bin/zsh -f
set -eu
stage=$PWD
mode=''
export SCENARIO=$1
export FINGERPRINT="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
install_wait() { shift; "$@"; }
install_message() { print -r -- "$*"; }
show_certificate_help() { print manual-help; }
capture_certificate_check() { "$1" "$2" > certificate-check.out 2> certificate-check.err; }
test_sudo() { shift 4; "$@"; }
""" + function + "\nrepair_certificate_access\n")
                result = subprocess.run(
                    ["/usr/bin/script", "-q", "/dev/null", "/bin/zsh", "-f", str(harness), scenario],
                    cwd=directory, capture_output=True, text=True, timeout=10,
                )
                calls = (directory / "calls").read_text().splitlines()
                if scenario == "complete":
                    self.assertEqual(calls, ["--check"])
                else:
                    self.assertEqual(calls, ["--check", "--repair " + "a" * 64, "--verify " + "a" * 64])
                if scenario == "verify-failed":
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn("manual-help", result.stdout)
                else:
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
