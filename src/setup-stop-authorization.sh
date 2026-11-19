#!/bin/sh
# Stop the GlobalProtect system job after sudo authorization, then try to save the narrow grant.
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
old_rule() {
  printf '%s ALL=(root) NOPASSWD:NOSETENV: %s check, %s disable, %s bootout' "$account" "$helper" "$helper" "$helper"
}
rule() {
  old_rule
  printf ', %s kill-residual\n' "$helper"
}

if [ "${1-}" = --print ]; then
  rule
  exit 0
fi

dir=/private/etc/sudoers.d
target="$dir/ashley-vpn-stop"
binary='/Applications/Ashley VPN.app/Contents/MacOS/ashley-vpn-menu'
if [ ! -f "$binary" ] || [ -L "$binary" ]; then
  echo "无法验证当前 Ashley VPN 安装，请重新安装后重试。" >&2
  exit 1
fi
identity=$(/usr/bin/stat -f '%d:%i:%B' "$binary")
checksum=$(/usr/bin/shasum -a 256 < "$binary")
if ! printf '%s\n' "$identity $checksum" | /usr/bin/grep -Eq '^[0-9]+:[0-9]+:[0-9]+ [0-9a-f]{64}  -$'; then
  echo "Invalid installation fingerprint." >&2
  exit 1
fi

process_functions="$(/usr/bin/dirname "$0")/gp-processes.sh"
. "$process_functions"

echo '管理员验证完成，正在停止 GlobalProtect 系统服务…'
system_job=system/com.paloaltonetworks.gp.pangpsd
/bin/launchctl disable "$system_job"
if /bin/launchctl print "$system_job" >/dev/null 2>&1; then
  if ! /bin/launchctl bootout "$system_job" && /bin/launchctl print "$system_job" >/dev/null 2>&1; then
    echo '无法卸载 GlobalProtect 系统服务。' >&2
    exit 1
  fi
fi
if _gp_processes | /usr/bin/awk '$2 == 0 { found=1 } END { exit !found }'; then
  /bin/sleep 1
  _gp_kill_root_processes
fi

if ! /usr/sbin/visudo -c -q ||
   ! /usr/bin/grep -Eq '^[[:space:]]*[@#]includedir[[:space:]]+(/private)?/etc/sudoers\.d([[:space:]]|$)' /private/etc/sudoers ||
   [ ! -d "$dir" ] || [ -L "$dir" ] || [ -L "$helper" ]; then
  echo '本次停止已执行。当前 sudo 配置无法保存免密授权，下次需要停止系统服务时会再次验证。'
  exit 0
fi

# A failure saving authorization must not prevent the caller from completing shutdown.
set +e
(
set -e
umask 077
stage=$(/usr/bin/mktemp -d /private/etc/.ashley-vpn-stop.XXXXXX)
trap 'for file in rule helper previous-rule legacy-rule; do
  if [ -e "$stage/$file" ]; then /bin/rm -- "$stage/$file"; fi
done
/bin/rmdir "$stage"' EXIT
rule > "$stage/rule"
/usr/sbin/chown root:wheel "$stage/rule"
/bin/chmod 0440 "$stage/rule"
/usr/sbin/visudo -c -q -f "$stage/rule"

old_rule > "$stage/legacy-rule"
printf '\n' >> "$stage/legacy-rule"
if [ -L "$target" ] || { [ -e "$target" ] && ! /usr/bin/cmp -s "$stage/rule" "$target" &&
     ! /usr/bin/cmp -s "$stage/legacy-rule" "$target"; }; then
  echo "Ashley VPN 的系统授权规则与当前账户不匹配，请联系 IT 核对 $target。" >&2
  exit 1
fi

{
  printf '#!/bin/sh\nexpected="%s %s"\n' "$identity" "$checksum"
  /bin/cat "$process_functions"
  /bin/cat <<'HELPER'
set -eu
case "$#" in 1) ;; *) exit 64 ;; esac
case "$1" in check|disable|bootout|kill-residual) ;; *) exit 64 ;; esac
binary='/Applications/Ashley VPN.app/Contents/MacOS/ashley-vpn-menu'
if [ ! -f "$binary" ] || [ -L "$binary" ]; then
  exit 77
fi
identity=$(/usr/bin/stat -f '%d:%i:%B' "$binary")
checksum=$(/usr/bin/shasum -a 256 < "$binary")
[ "$identity $checksum" = "$expected" ] || exit 77
[ "$1" != check ] || exit 0
if [ "$1" = kill-residual ]; then
  ! /bin/launchctl print system/com.paloaltonetworks.gp.pangpsd >/dev/null 2>&1 || exit 1
  _gp_kill_root_processes
  exit 0
fi
exec /bin/launchctl "$1" system/com.paloaltonetworks.gp.pangpsd
HELPER
} > "$stage/helper"
/usr/sbin/chown root:wheel "$stage/helper"
/bin/chmod 0555 "$stage/helper"
/bin/sh -n "$stage/helper"

/bin/mv -f "$stage/helper" "$helper"
if ! /usr/bin/cmp -s "$stage/rule" "$target"; then
  if [ -e "$target" ]; then
    /bin/cp -p "$target" "$stage/previous-rule"
  fi
  /bin/mv "$stage/rule" "$target"
  if ! /usr/sbin/visudo -c -q; then
    if [ -e "$stage/previous-rule" ]; then
      /bin/mv -f "$stage/previous-rule" "$target"
    else
      /bin/rm -- "$target"
    fi
    echo 'Ashley VPN 的新免密规则未通过检查，已还原。' >&2
    exit 1
  fi
fi
)
save_status=$?
set -e
if [ "$save_status" -eq 0 ]; then
  echo '已保存本次安装的停止授权。'
else
  echo '本次停止已执行，但未能保存免密授权。下次需要停止系统服务时会再次验证。'
fi
