#!/bin/zsh -f
# Invoked in a new Terminal window to leave existing terminal input untouched.
emulate -L zsh
umask 077

ASHLEY_VPN_RESOURCES=${0:A:h}
ASHLEY_VPN_STATE="$HOME/Library/Application Support/Ashley VPN"
source "$ASHLEY_VPN_RESOURCES/check-globalprotect.sh"
check_globalprotect || exit 1

/bin/mkdir -p "$ASHLEY_VPN_STATE" || exit 1
zmodload zsh/system || exit 1
: >> "$ASHLEY_VPN_STATE/operation.lock" || exit 1
if ! zsystem flock -t 0 -f operation_fd "$ASHLEY_VPN_STATE/operation.lock"; then
  print -u2 -- 'Ashley VPN 正在运行另一项操作，请查看先前打开的终端窗口。'
  exit 1
fi

source "$ASHLEY_VPN_RESOURCES/globalprotect-control.zsh" || exit 1
case "$1" in
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
