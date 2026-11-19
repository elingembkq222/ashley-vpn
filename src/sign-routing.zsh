#!/bin/zsh -f
set -eu
root=${0:A:h}
app=$1
identity=${ASHLEY_SIGN_IDENTITY:?Developer ID Application signing identity required}
host_profile=${ASHLEY_HOST_PROFILE:?host provisioning profile required}
provider_profile=${ASHLEY_PROVIDER_PROFILE:?provider provisioning profile required}
notary_profile=${ASHLEY_NOTARY_PROFILE:?notarytool keychain profile required}
identifier=com.ashley.vpn.companion.routing
extension="$app/Contents/Library/SystemExtensions/$identifier.systemextension"
temp=$(/usr/bin/mktemp -d)
trap '/bin/rm -R -- "$temp"' EXIT
/usr/bin/security cms -D -i "$host_profile" > "$temp/host.plist"
/usr/bin/security cms -D -i "$provider_profile" > "$temp/provider.plist"
team=$(/usr/bin/python3 - "$temp" <<'PY'
import datetime
import pathlib
import plistlib
import sys

folder = pathlib.Path(sys.argv[1])
teams = set()
for role, identifier in [("host", "com.ashley.vpn.companion"), ("provider", "com.ashley.vpn.companion.routing")]:
    profile = plistlib.loads((folder / (role + ".plist")).read_bytes())
    team = profile["TeamIdentifier"][0]
    teams.add(team)
    allowed = profile["Entitlements"]
    requested = {"com.apple.application-identifier": team + "." + identifier,
                 "com.apple.developer.team-identifier": team,
                 "com.apple.developer.networking.networkextension": ["app-proxy-provider-systemextension"]}
    if role == "host":
        requested["com.apple.developer.system-extension.install"] = True
    else:
        requested["com.apple.security.application-groups"] = [team + ".com.ashley.vpn.companion.routing"]
    if profile["ExpirationDate"] <= datetime.datetime.utcnow():
        sys.exit(role + " profile expired")
    for key, value in requested.items():
        if isinstance(value, list):
            valid = set(value).issubset(allowed.get(key, []))
        else:
            valid = allowed.get(key) == value
        if not valid:
            sys.exit(role + " profile does not authorize " + key)
    (folder / (role + ".entitlements")).write_bytes(plistlib.dumps(requested))
if len(teams) != 1:
    sys.exit("Signing teams must match")
print(teams.pop())
PY
)
/bin/mkdir -p "$extension/Contents/MacOS"
/bin/cp "$root/routing/Info.plist" "$extension/Contents/Info.plist"
for key in CFBundleVersion CFBundleShortVersionString; do
  value=$(/usr/bin/plutil -extract "$key" raw -o - "$app/Contents/Info.plist")
  /usr/bin/plutil -insert "$key" -string "$value" "$extension/Contents/Info.plist"
done
/usr/bin/plutil -insert NetworkExtension.NEMachServiceName -string "$team.$identifier.service" "$extension/Contents/Info.plist"
/usr/bin/xcrun swiftc -O -target "$(/usr/bin/uname -m)-apple-macos14.0" \
  "$root"/routing/*.swift "$root/CodexProxyStatus.swift" -o "$extension/Contents/MacOS/CodexRouting"
/bin/cp "$host_profile" "$app/Contents/embedded.provisionprofile"
/bin/cp "$provider_profile" "$extension/Contents/embedded.provisionprofile"
for component in wifi-keychain globalprotect-keychain; do
  /usr/bin/codesign --force --timestamp --options runtime --sign "$identity" "$app/Contents/Resources/$component"
done
/usr/bin/codesign --force --timestamp --options runtime --entitlements "$temp/provider.entitlements" --sign "$identity" "$extension"
/usr/bin/codesign --force --timestamp --options runtime --entitlements "$temp/host.entitlements" --sign "$identity" "$app"
/usr/bin/codesign --verify --deep --strict -R "anchor apple generic and certificate leaf[subject.OU] = \"$team\"" "$app"
/usr/bin/ditto -c -k --keepParent "$app" "$temp/AshleyVPN.zip"
/usr/bin/xcrun notarytool submit "$temp/AshleyVPN.zip" --keychain-profile "$notary_profile" --wait
/usr/bin/xcrun stapler staple "$app"
/usr/bin/xcrun stapler validate "$app"
