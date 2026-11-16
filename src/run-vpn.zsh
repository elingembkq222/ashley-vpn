#!/bin/zsh -f
# Invoked in a new Terminal window to leave existing terminal input untouched.
emulate -L zsh
umask 077

ASHLEY_VPN_RESOURCES=${0:A:h}
ASHLEY_VPN_STATE="$HOME/Library/Application Support/Ashley VPN"
source "$ASHLEY_VPN_RESOURCES/globalprotect-control.zsh" || exit 1

vpn_state() {
  if [[ "$(_gp-vpn-current-state)" == connected ]]; then
    print -r -- connected
  elif _gp-already-stopped; then
    print -r -- stopped
  else
    print -r -- running
  fi
}

/bin/mkdir -p "$ASHLEY_VPN_STATE" || exit 1
zmodload zsh/system || exit 1
: >> "$ASHLEY_VPN_STATE/operation.lock" || exit 1
if [[ "$1" == status ]]; then
  busy=idle
  if zsystem flock -t 0 -f operation_fd "$ASHLEY_VPN_STATE/operation.lock" 2>/dev/null; then
    zsystem flock -u "$operation_fd" || exit 1
  else
    busy=busy
  fi
  print -r -- "$busy $(vpn_state)"
  exit 0
fi
source "$ASHLEY_VPN_RESOURCES/check-globalprotect.sh"
check_globalprotect || exit 1
if ! zsystem flock -t 0 -f operation_fd "$ASHLEY_VPN_STATE/operation.lock"; then
  print -u2 -- 'Ashley VPN 正在运行另一项操作，请查看先前打开的终端窗口。'
  exit 1
fi

case "$1" in
  toggle)
    if [[ "$(vpn_state)" == stopped ]]; then
      gp-connect
    else
      gp-stop && wifi-switch "$GP_HOME_WIFI"
    fi
    ;;
  connect)
    gp-connect
    ;;
  disconnect)
    gp-stop && wifi-switch "$GP_HOME_WIFI"
    ;;
  *)
    print -u2 -- '未知的 Ashley VPN 操作。'
    exit 2
    ;;
esac
