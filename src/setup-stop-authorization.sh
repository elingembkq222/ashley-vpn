#!/bin/sh
# Grant this Mac account permission to stop only the GlobalProtect system job.
set -eu

case "${1-}" in
  --print)
    account=$(/usr/bin/id -un)
    ;;
  '')
    if [ "$(/usr/bin/id -u)" != 0 ] || [ -z "${SUDO_USER-}" ] || [ "$SUDO_USER" = root ]; then
      echo "Run this installer once with sudo from your own Mac account." >&2
      exit 1
    fi
    account=$SUDO_USER
    ;;
  *)
    echo "Usage: $0 [--print]" >&2
    exit 2
    ;;
esac

case "$account" in
  ''|[!A-Za-z0-9_]*|*[!A-Za-z0-9_.-]*)
    echo "Unsupported macOS account name." >&2
    exit 1
    ;;
esac

helper=/private/etc/ashley-vpn-stop
rule() {
  printf '%s ALL=(root) NOPASSWD:NOSETENV: %s check, %s disable, %s bootout\n' "$account" "$helper" "$helper" "$helper"
}

if [ "${1-}" = --print ]; then
  rule
  exit 0
fi

dir=/private/etc/sudoers.d
target="$dir/ashley-vpn-stop"
binary='/Applications/Ashley VPN.app/Contents/MacOS/ashley-vpn-menu'
/usr/sbin/visudo -c -q
if ! /usr/bin/grep -Eq '^[[:space:]]*[@#]includedir[[:space:]]+(/private)?/etc/sudoers\.d([[:space:]]|$)' /private/etc/sudoers; then
  echo "The system sudoers configuration does not include /etc/sudoers.d." >&2
  exit 1
fi
if [ ! -f "$binary" ] || [ -L "$binary" ] || [ -L "$helper" ]; then
  echo "Cannot identify the installed Black Cat Assistant." >&2
  exit 1
fi
identity=$(/usr/bin/stat -f '%d:%i:%B' "$binary")
checksum=$(/usr/bin/shasum -a 256 < "$binary")
if ! printf '%s\n' "$identity $checksum" | /usr/bin/grep -Eq '^[0-9]+:[0-9]+:[0-9]+ [0-9a-f]{64}  -$'; then
  echo "Invalid installation fingerprint." >&2
  exit 1
fi

umask 077
stage=$(/usr/bin/mktemp -d /private/etc/.ashley-vpn-stop.XXXXXX)
trap 'for file in rule helper; do
  if [ -e "$stage/$file" ]; then /bin/rm -- "$stage/$file"; fi
done
/bin/rmdir "$stage"' EXIT
rule > "$stage/rule"
/usr/sbin/chown root:wheel "$stage/rule"
/bin/chmod 0440 "$stage/rule"
/usr/sbin/visudo -c -q -f "$stage/rule"

if [ -L "$target" ] || { [ -e "$target" ] && ! /usr/bin/cmp -s "$stage/rule" "$target"; }; then
  echo "A different rule already exists at $target. No changes made." >&2
  exit 1
fi

{
  printf '#!/bin/sh\nexpected="%s %s"\n' "$identity" "$checksum"
  /bin/cat <<'HELPER'
set -eu
case "$#" in 1) ;; *) exit 64 ;; esac
case "$1" in check|disable|bootout) ;; *) exit 64 ;; esac
binary='/Applications/Ashley VPN.app/Contents/MacOS/ashley-vpn-menu'
if [ ! -f "$binary" ] || [ -L "$binary" ]; then
  exit 77
fi
identity=$(/usr/bin/stat -f '%d:%i:%B' "$binary")
checksum=$(/usr/bin/shasum -a 256 < "$binary")
[ "$identity $checksum" = "$expected" ] || exit 77
[ "$1" != check ] || exit 0
exec /bin/launchctl "$1" system/com.paloaltonetworks.gp.pangpsd
HELPER
} > "$stage/helper"
/usr/sbin/chown root:wheel "$stage/helper"
/bin/chmod 0555 "$stage/helper"
/bin/sh -n "$stage/helper"

/bin/mv -f "$stage/rule" "$target"
if ! /usr/sbin/visudo -c -q; then
  /bin/rm -- "$target"
  echo "Installed rule did not pass validation and was removed." >&2
  exit 1
fi
/bin/mv -f "$stage/helper" "$helper"
echo "Authorized stopping GlobalProtect for this installation. No password is stored."
