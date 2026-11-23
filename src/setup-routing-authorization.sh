#!/bin/sh
# One installation-level helper. Runtime switching uses its authenticated local socket.
set -eu
# Keep failures observable without recording any password or credential.
exec >> /var/log/ashley-vpn-routing-install.log 2>&1
trap 'result=$?; echo "routing-install exit=$result"' EXIT
set -x
umask 077
[ "$(/usr/bin/id -u)" = 0 ] || exit 77
case "${1-}" in ''|*[!0-9]*) exit 64 ;; esac
uid=$1
account=$(/usr/bin/id -un "$uid")
case "$account" in ''|root|*[!A-Za-z0-9_.-]*) exit 64 ;; esac
resources='/Applications/Ashley VPN.app/Contents/Resources'
identity=$(/bin/cat "$resources/installation-id")
printf '%s\n' "$identity" | /usr/bin/grep -Eq '^[A-Fa-f0-9-]{36}$' || exit 77
helper='/Library/PrivilegedHelperTools/com.ashley.vpn.routing'
receipt='/Library/Application Support/Ashley VPN Routing/installation.plist'
daemon='/Library/LaunchDaemons/com.ashley.vpn.routing-pac.plist'
for path in "$helper" "$receipt" "$daemon" '/Library/Application Support/Ashley VPN Routing'; do
  [ ! -L "$path" ] || exit 77
done
stage=$(/usr/bin/mktemp -d /private/tmp/ashley-routing-install.XXXXXX)
trap '/bin/rm -rf "$stage"' EXIT
/bin/cp "$resources/routing-service" "$stage/helper"
/usr/bin/codesign --verify --strict "$stage/helper"
/usr/bin/plutil -create xml1 "$stage/receipt"
/usr/bin/plutil -insert uid -string "$uid" "$stage/receipt"
/usr/bin/plutil -insert installation -string "$identity" "$stage/receipt"
/bin/cat > "$stage/daemon" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.ashley.vpn.routing-pac</string>
<key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/com.ashley.vpn.routing</string><string>serve</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>StandardErrorPath</key><string>/var/log/ashley-vpn-routing.log</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$stage/daemon" >/dev/null
/bin/mkdir -p /Library/PrivilegedHelperTools '/Library/Application Support/Ashley VPN Routing'
/usr/sbin/chown root:wheel '/Library/Application Support/Ashley VPN Routing'
/bin/chmod 0755 '/Library/Application Support/Ashley VPN Routing'
/usr/bin/install -o root -g wheel -m 0555 "$stage/helper" "$helper"
/usr/bin/install -o root -g wheel -m 0644 "$stage/receipt" "$receipt"
/usr/bin/install -o root -g wheel -m 0644 "$stage/daemon" "$daemon"
/bin/launchctl bootout system/com.ashley.vpn.routing-pac >/dev/null 2>&1 || true
/bin/launchctl bootstrap system "$daemon"
echo '已保存本次安装的网络与 VPN 停止授权。后续切换无需密码。'
