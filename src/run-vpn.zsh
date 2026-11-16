#!/bin/zsh -f
# Invoked in a new Terminal window to leave existing terminal input untouched.
emulate -L zsh
umask 077

ASHLEY_VPN_RESOURCES=${0:A:h}
ASHLEY_VPN_STATE="$HOME/Library/Application Support/Ashley VPN"
operation_owner="$ASHLEY_VPN_STATE/operation.owner"
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

connect_vpn() {
  gp-check-connect-network || return
  local installation_id last_connected=''
  if ! IFS= read -r installation_id < "$ASHLEY_VPN_RESOURCES/installation-id" ||
     [[ -z "$installation_id" ]]; then
    print -ru2 -- '无法读取 Ashley VPN 安装标识，请重新运行安装脚本。'
    return 1
  fi
  { IFS= read -r last_connected < "$ASHLEY_VPN_STATE/connected-installation"; } 2>/dev/null
  if [[ "$last_connected" == "$installation_id" ]]; then
    gp-connect
    return
  fi
  if ! _gp-already-stopped; then
    print -r -- '首次连接前检测到 GlobalProtect 正在运行，正在关闭现有服务…'
    if ! gp-stop; then
      print -ru2 -- '未确认 GlobalProtect 已停止，已取消本次连接。'
      return 1
    fi
  fi
  gp-connect || return
  if ! print -r -- "$installation_id" > "$ASHLEY_VPN_STATE/connected-installation"; then
    print -ru2 -- 'VPN 已连接，但未能记录本次安装已完成首次连接。'
  fi
}

process_start() {
  LC_ALL=C /bin/ps -p "$1" -o lstart= | /usr/bin/awk '{$1=$1; if (NF) print}'
}

cancel_operation() {
  local token pid action started group command script
  if zsystem flock -t 0 -f idle_fd "$ASHLEY_VPN_STATE/operation.lock" 2>/dev/null; then
    zsystem flock -u "$idle_fd"
    return 3
  fi
  { read -r token pid action started < "$operation_owner"; } 2>/dev/null || return 3
  [[ -n "$1" && "$token" == "$1" ]] || return 3
  [[ -n "$pid" && "$pid" != *[^0-9]* && "$pid" -gt 1 ]] || return 2
  case "$action" in toggle|connect|disconnect) ;; *) return 2 ;; esac
  [[ -n "$started" && "$(process_start "$pid")" == "$started" ]] || return 3
  group=$(/bin/ps -p "$pid" -o pgid= | /usr/bin/awk '{$1=$1; if (NF) print}')
  command=$(/bin/ps -ww -p "$pid" -o command=)
  # The Terminal launcher runs the operation in its own foreground job. Never signal the
  # login shell, a reused PID, or GlobalProtect processes owned by launchd.
  [[ "$group" == "$pid" && "$command" == "/bin/zsh -f "*" $action" ]] || return 2
  script=${command#"/bin/zsh -f "}
  script=${script%" $action"}
  [[ "${script:A}" == "$ASHLEY_VPN_RESOURCES/run-vpn.zsh" ]] || return 2
  /bin/kill -INT -- "-$pid"
}

/bin/mkdir -p "$ASHLEY_VPN_STATE" || exit 1
zmodload zsh/system || exit 1
: >> "$ASHLEY_VPN_STATE/operation.lock" || exit 1
if [[ "$1" == status ]]; then
  busy=idle
  token=-
  if zsystem flock -t 0 -f operation_fd "$ASHLEY_VPN_STATE/operation.lock" 2>/dev/null; then
    zsystem flock -u "$operation_fd" || exit 1
  else
    busy=busy
    { read -r token _ < "$operation_owner"; } 2>/dev/null || token=-
  fi
  print -r -- "$busy $(vpn_state) $token"
  exit 0
fi
if [[ "$1" == cancel ]]; then
  cancel_operation "$2"
  exit $?
fi
case "$1" in
  toggle|connect|disconnect) ;;
  *) print -u2 -- '未知的 Ashley VPN 操作。'; exit 2 ;;
esac
source "$ASHLEY_VPN_RESOURCES/check-globalprotect.sh"
check_globalprotect || exit 1
if ! zsystem flock -t 0 -f operation_fd "$ASHLEY_VPN_STATE/operation.lock"; then
  print -u2 -- 'Ashley VPN 正在运行另一项操作，请查看先前打开的终端窗口。'
  exit 1
fi

started=$(process_start "$$")
[[ -n "$started" ]] || exit 1
token=$(/usr/bin/uuidgen) || exit 1
trap '/bin/rm -- "$operation_owner" 2>/dev/null' EXIT
trap 'print -u2 -- "已取消本次 VPN 操作。"; exit 130' INT
print -r -- "$token $$ $1 $started" > "$operation_owner" || exit 1

case "$1" in
  toggle)
    if [[ "$(vpn_state)" == stopped ]]; then
      connect_vpn
    else
      gp-disconnect
    fi
    ;;
  connect)
    connect_vpn
    ;;
  disconnect)
    gp-disconnect
    ;;
esac
