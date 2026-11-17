#!/bin/zsh -f
# The menu app runs this in the background and opens Terminal only for input.
emulate -L zsh
umask 077

ASHLEY_VPN_RESOURCES=${0:A:h}
ASHLEY_VPN_STATE="$HOME/Library/Application Support/Ashley VPN"
operation_owner="$ASHLEY_VPN_STATE/operation.owner"
operation_progress="$ASHLEY_VPN_STATE/operation.progress"
operation_input="$ASHLEY_VPN_STATE/operation.input"
ASHLEY_VPN_INPUT='' ASHLEY_VPN_INPUT_MODE=''
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
  gp-connect reset || return
  if ! print -r -- "$installation_id" > "$ASHLEY_VPN_STATE/connected-installation"; then
    print -ru2 -- 'VPN 已连接，但未能记录本次安装已完成首次连接。'
  fi
}

process_start() {
  LC_ALL=C /bin/ps -p "$1" -o lstart= | /usr/bin/awk '{$1=$1; if (NF) print}'
}

_gp-gui-progress() {
  [[ "$ASHLEY_VPN_BACKGROUND" == 1 ]] || return 0
  printf '%s\n' "$1" "${gpProgressStep:-}" "${2:-}" > "$operation_progress.$$" &&
    /bin/mv -f -- "$operation_progress.$$" "$operation_progress"
}

_gp-terminal-input() {
  local name result attempt pid started
  ASHLEY_VPN_INPUT=$(/usr/bin/mktemp -d "$ASHLEY_VPN_STATE/input.$token.XXXXXX") || return 1
  ASHLEY_VPN_INPUT_MODE="$1"
  name=${ASHLEY_VPN_INPUT:t}
  case "$1" in
    *-system) _gp-gui-progress '请在终端完成管理员验证' ;;
    *) _gp-gui-progress '请在终端选择 Wi-Fi' ;;
  esac
  print -r -- "$1 $name $$ ${gpProgressStep:-}" > "$ASHLEY_VPN_INPUT/request" || return 1
  print -r -- "$1 $name" > "$operation_input.$$" && /bin/mv -f -- "$operation_input.$$" "$operation_input" || return 1
  for attempt in {1..60}; do
    [[ -f "$ASHLEY_VPN_INPUT/owner" || -f "$ASHLEY_VPN_INPUT/result" ]] && break
    /bin/sleep 0.25
  done
  while [[ ! -f "$ASHLEY_VPN_INPUT/result" ]]; do
    { read -r pid started < "$ASHLEY_VPN_INPUT/owner"; } 2>/dev/null || break
    [[ "$(process_start "$pid")" == "$started" ]] || break
    /bin/sleep 0.25
  done
  result=1
  { read -r result < "$ASHLEY_VPN_INPUT/result"; } 2>/dev/null || result=1
  _gp-clear-input
  [[ "$result" == <0-255> ]] || return 1
  (( result == 0 || result == 130 )) || print -ru2 -- '终端输入未完成，请重试。'
  return "$result"
}

_gp-clear-input() {
  [[ -n "$ASHLEY_VPN_INPUT" ]] || return 0
  /bin/rm -f -- "$operation_input" "$ASHLEY_VPN_INPUT"/{request,owner,owner.tmp,result,result.tmp}
  /bin/rmdir -- "$ASHLEY_VPN_INPUT" 2>/dev/null
  ASHLEY_VPN_INPUT=''
}

_gp-cancel-input() {
  [[ -n "$ASHLEY_VPN_INPUT" ]] || return 0
  local pid started group command script suffix
  { read -r pid started < "$ASHLEY_VPN_INPUT/owner"; } 2>/dev/null || return 0
  [[ "$pid" == <2-> && -n "$started" && "$(process_start "$pid")" == "$started" ]] || return 0
  command=$(/bin/ps -ww -p "$pid" -o command=)
  suffix=" input $ASHLEY_VPN_INPUT_MODE ${ASHLEY_VPN_INPUT:t}"
  [[ "$command" == '/bin/zsh -f '*"$suffix" ]] || return 0
  script=${command#'/bin/zsh -f '}
  script=${script%"$suffix"}
  [[ "${script:A}" == "$ASHLEY_VPN_RESOURCES/run-vpn.zsh" ]] || return 0
  group=$(/bin/ps -p "$pid" -o pgid= | /usr/bin/awk '{$1=$1; print}')
  if [[ "$group" == "$pid" ]]; then
    /bin/kill -INT -- "-$pid" 2>/dev/null
  else
    /bin/kill -INT -- "$pid" 2>/dev/null
  fi
  while [[ ! -f "$ASHLEY_VPN_INPUT/result" && "$(process_start "$pid")" == "$started" ]]; do
    /bin/sleep 0.25
  done
}

_gp-run-input() {
  local mode="$1" name="$2" owner_mode owner_name owner_pid started gpProgressStep
  [[ "$name" =~ '^input\.[[:xdigit:]-]+\.[[:alnum:]]+$' && -t 0 && -t 2 ]] || return 2
  local input_path="$ASHLEY_VPN_STATE/$name"
  { read -r owner_mode owner_name owner_pid gpProgressStep < "$input_path/request"; } 2>/dev/null || return 2
  [[ "$owner_mode" == "$mode" && "$owner_name" == "$name" && "$owner_pid" == <2-> ]] || return 2
  started=$(process_start "$$")
  [[ -n "$started" ]] || return 1
  terminal_input_path="$input_path"
  trap 'result=$?; if [[ -d "$terminal_input_path" ]]; then print -r -- "$result" > "$terminal_input_path/result.tmp" && /bin/mv -f -- "$terminal_input_path/result.tmp" "$terminal_input_path/result"; fi' EXIT
  trap 'exit 130' INT HUP TERM
  print -r -- "$$ $started" > "$input_path/owner.tmp" && /bin/mv -f -- "$input_path/owner.tmp" "$input_path/owner" || exit 1
  /bin/kill -0 "$owner_pid" 2>/dev/null && [[ -f "$input_path/request" ]] || exit 2
  ASHLEY_VPN_BACKGROUND=1
  [[ "${TERM:-dumb}" == dumb ]] || printf '\033[H\033[2J' >&2
  case "$mode" in
    connect-wifi|connect-wifi-reset)
      _gp-terminal-title '连接集团 VPN'
      if [[ "$mode" == connect-wifi-reset ]]; then _gp-connect-wifi reset; else _gp-connect-wifi; fi
      ;;
    disconnect-wifi)
      _gp-terminal-title '切换 Wi-Fi'
      _gp-disconnect-wifi
      ;;
    stop-system)
      _gp-terminal-title '关闭集团 VPN'
      _gp-authorize-stop
      ;;
    start-system)
      _gp-terminal-title '连接集团 VPN'
      _gp-terminal-message warning '◆' '启动 GlobalProtect 系统服务可能需要本机管理员授权。'
      _gp-start-service system com.paloaltonetworks.gp.pangpsd /Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist
      ;;
    *) exit 2 ;;
  esac
  exit $?
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
  if [[ "$busy" == busy && "$token" != - ]]; then
    progress='' step='' remaining=''
    {
      IFS= read -r progress
      IFS= read -r step
      IFS= read -r remaining
    } < "$operation_progress" 2>/dev/null || true
    { IFS= read -r input < "$operation_input"; } 2>/dev/null || input=''
    printf '%s\n' "$progress" "$input" "$step" "$remaining"
  fi
  exit 0
fi
if [[ "$1" == cancel ]]; then
  cancel_operation "$2"
  exit $?
fi
if [[ "$1" == input ]]; then
  _gp-run-input "$2" "$3"
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
trap '_gp-clear-input; /bin/rm -f -- "$operation_owner" "$operation_progress" "$operation_progress.$$" "$operation_input" "$operation_input.$$"' EXIT
trap 'trap "" INT; _gp-cancel-input; print -u2 -- "已取消本次 VPN 操作。"; exit 130' INT
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
