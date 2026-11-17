# GlobalProtect manual controls. Loading this file does not change VPN state.
# The installed GUI PanGPS launcher uses the same setuid binary as pangpsd.

_gp-launchctl() {
  emulate -L zsh
  local gpDomain="$1"
  shift
  if [[ "$gpDomain" == system ]]; then
    sudo /bin/launchctl "$@"
  else
    /bin/launchctl "$@"
  fi
}

# Keep blocking commands in the foreground so their stdin and exit code are
# unchanged. The terminal alone gets a heartbeat during a long operation.
_gp-progress-run() {
  emulate -L zsh
  local gpMessage="$1" gpTicker gpStatus
  shift
  if [[ "$ASHLEY_VPN_BACKGROUND" == 1 ]]; then
    _gp-gui-progress "$gpMessage"
    "$@"
    return
  fi
  if [[ ! -t 2 ]]; then
    "$@"
    return
  fi
  print -ru2 -- "$gpMessage…"
  (
    local gpElapsed gpSleep=''
    trap 'if [[ -n "$gpSleep" ]]; then kill "$gpSleep" 2>/dev/null; fi; exit 0' TERM
    for (( gpElapsed = 4; ; gpElapsed += 4 )); do
      /bin/sleep 4 &
      gpSleep=$!
      wait "$gpSleep" || exit
      gpSleep=''
      print -ru2 -- "$gpMessage… 已等待约 ${gpElapsed} 秒"
    done
  ) &
  gpTicker=$!
  {
    "$@"
    gpStatus=$?
  } always {
    kill "$gpTicker" 2>/dev/null
    wait "$gpTicker" 2>/dev/null
  }
  return "$gpStatus"
}

_gp-start-service() {
  emulate -L zsh
  local gpDomain="$1" gpLabel="$2" gpPlist="$3"
  local gpTarget="$gpDomain/$gpLabel"
  if [[ ! -r "$gpPlist" ]]; then
    print -u2 -- "GlobalProtect 配置文件不存在或不可读：$gpPlist"
    return 1
  fi
  _gp-launchctl "$gpDomain" enable "$gpTarget" || return
  local gpInfo
  if gpInfo=$(/bin/launchctl print "$gpTarget" 2>/dev/null); then
    # Start an idle service without restarting an already running VPN process.
    if ! print -r -- "$gpInfo" | /usr/bin/awk '/^[[:space:]]*state = running$/ { found=1 } END { exit !found }'; then
      _gp-launchctl "$gpDomain" kickstart "$gpTarget" || return
    fi
  else
    _gp-launchctl "$gpDomain" bootstrap "$gpDomain" "$gpPlist" || return
  fi
  /bin/launchctl print "$gpTarget" >/dev/null 2>&1 || {
    print -u2 -- "服务加载后无法查询：$gpTarget"
    return 1
  }
}

gp-start() {
  emulate -L zsh
  if (( EUID == 0 )); then
    print -u2 -- '请在当前登录用户的终端运行 gp-start，不要使用 sudo gp-start。'
    return 1
  fi
  local gpGui="gui/$EUID"
  local gpGuiLoaded=0 gpSystemLoaded=0
  /bin/launchctl print "$gpGui/com.paloaltonetworks.gp.pangps" >/dev/null 2>&1 && gpGuiLoaded=1
  /bin/launchctl print system/com.paloaltonetworks.gp.pangpsd >/dev/null 2>&1 && gpSystemLoaded=1
  if (( gpGuiLoaded && gpSystemLoaded )); then
    print -u2 -- '检测到两套 PanGPS 启动服务均已加载；请先运行 gp-status 核对，再用 gp-stop 停止后重新启动。'
    return 1
  fi
  if (( gpSystemLoaded )); then
    if [[ "$ASHLEY_VPN_BACKGROUND" == 1 && ! -t 0 ]]; then
      _gp-terminal-input start-system || return
    else
      _gp-start-service system com.paloaltonetworks.gp.pangpsd \
        /Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist || return
    fi
  else
    _gp-start-service "$gpGui" com.paloaltonetworks.gp.pangps \
      /Library/LaunchAgents/com.paloaltonetworks.gp.pangps.plist || return
  fi
  _gp-start-service "$gpGui" com.paloaltonetworks.gp.pangpa \
    /Library/LaunchAgents/com.paloaltonetworks.gp.pangpa.plist || return
  local gpAttempt
  for gpAttempt in {1..5}; do
    if /usr/bin/pgrep -x PanGPS >/dev/null && /usr/bin/pgrep -x GlobalProtect >/dev/null; then
      print -- 'GlobalProtect 客户端已启动。'
      return 0
    fi
    /bin/sleep 1
  done
  print -u2 -- '服务已加载，但尚未确认 PanGPS 和 GlobalProtect 进程均在运行。'
  gp-status
  return 1
}

_gp-authorize-stop() {
  emulate -L zsh
  local gpInstaller="$ASHLEY_VPN_RESOURCES/setup-stop-authorization.sh"
  [[ -t 0 && -t 2 && -r "$gpInstaller" ]] || return 1
  _gp-terminal-message warning '◆' '停止 GlobalProtect 系统服务需要本机管理员授权。'
  /usr/bin/sudo -k -p '  本机管理员密码：' -- /bin/sh "$gpInstaller"
}

_gp-stop-system-service() {
  emulate -L zsh
  local gpSystemJob="$1" gpOutput gpStatus
  local gpHelper=/private/etc/ashley-vpn-stop

  gpOutput=$(LC_ALL=C /usr/bin/sudo -kn -- "$gpHelper" check 2>&1)
  gpStatus=$?
  if (( gpStatus == 0 )); then
    /usr/bin/sudo -kn -- "$gpHelper" disable || return
    if /bin/launchctl print "$gpSystemJob" >/dev/null 2>&1; then
      _gp-progress-run '正在停止 GlobalProtect 系统服务' /usr/bin/sudo -kn -- "$gpHelper" bootout ||
        ! /bin/launchctl print "$gpSystemJob" >/dev/null 2>&1 || return 1
    fi
    return 0
  fi
  if (( gpStatus != 77 )) && [[ "$gpOutput" != 'sudo: a password is required' &&
      "$gpOutput" != "sudo: $gpHelper: command not found" ]]; then
    print -ru2 -- "$gpOutput"
    return "$gpStatus"
  fi
  if [[ "$ASHLEY_VPN_BACKGROUND" == 1 && ! -t 0 ]]; then
    _gp-terminal-input stop-system
  else
    _gp-authorize-stop
  fi
}

_gp-already-stopped() {
  emulate -L zsh
  local gpGui="gui/$EUID" gpJob
  if /usr/bin/pgrep -x 'PanGPS|GlobalProtect' >/dev/null; then
    return 1
  fi
  for gpJob in "$gpGui/com.paloaltonetworks.gp.pangpa" "$gpGui/com.paloaltonetworks.gp.pangps" \
               system/com.paloaltonetworks.gp.pangpsd; do
    if /bin/launchctl print "$gpJob" >/dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}

gp-stop() {
  emulate -L zsh
  if (( EUID == 0 )); then
    print -u2 -- '请在当前登录用户的终端运行 gp-stop，不要使用 sudo gp-stop。'
    return 1
  fi
  if _gp-already-stopped; then
    print -r -- 'GlobalProtect 已停止。'
    return 0
  fi
  [[ "$ASHLEY_VPN_BACKGROUND" != 1 ]] || _gp-gui-progress '正在关闭 GlobalProtect'
  print -r -- '正在关闭 GlobalProtect…'
  local gpGui="gui/$EUID"
  local gpSystemJob='system/com.paloaltonetworks.gp.pangpsd' gpSystemDisabled
  gpSystemDisabled=$(/bin/launchctl print-disabled system 2>/dev/null)
  # A disabled and unloaded system job needs no privileged changes.
  if { [[ "$gpSystemDisabled" != *'"com.paloaltonetworks.gp.pangpsd" => disabled'* ]] &&
       [[ "$gpSystemDisabled" != *'"com.paloaltonetworks.gp.pangpsd" => true'* ]]; } ||
     /bin/launchctl print "$gpSystemJob" >/dev/null 2>&1; then
    _gp-stop-system-service "$gpSystemJob" || return
  fi
  _gp-launchctl "$gpGui" disable "$gpGui/com.paloaltonetworks.gp.pangpa" || return
  _gp-launchctl "$gpGui" disable "$gpGui/com.paloaltonetworks.gp.pangps" || return
  local gpTarget gpBootout gpStep
  for gpTarget in \
    "$gpGui/com.paloaltonetworks.gp.pangpa" \
    "$gpGui/com.paloaltonetworks.gp.pangps"; do
    if /bin/launchctl print "$gpTarget" >/dev/null 2>&1; then
      case "$gpTarget" in
        */com.paloaltonetworks.gp.pangpa) gpStep='正在退出 GlobalProtect 界面' ;;
        *) gpStep='正在停止 GlobalProtect 服务并断开 VPN' ;;
      esac
      _gp-progress-run "$gpStep" _gp-launchctl "$gpGui" bootout "$gpTarget"
      gpBootout=$?
      if (( gpBootout != 0 )) && /bin/launchctl print "$gpTarget" >/dev/null 2>&1; then
        return "$gpBootout"
      fi
    fi
  done

  # bootout can return before launchd completes teardown. Check all jobs and
  # processes together so a stopped VPN finishes as soon as cleanup completes.
  [[ "$ASHLEY_VPN_BACKGROUND" != 1 ]] || _gp-gui-progress '正在确认 GlobalProtect 已退出'
  local gpDeadline=$((SECONDS + 25))
  while true; do
    if _gp-already-stopped; then
      print -- '关闭完成：VPN 已断开，GlobalProtect 已停止。'
      return 0
    fi
    (( SECONDS < gpDeadline )) || break
    /bin/sleep 0.25
  done
  gp-status
  print -u2 -- '未能确认 GlobalProtect 进程和服务已完全退出。'
  return 1
}

gp-status() {
  emulate -L zsh
  local gpGui="gui/$EUID"
  local gpTarget gpDomain gpLabel gpInfo gpDisabled gpDisableText
  for gpTarget in \
    "$gpGui/com.paloaltonetworks.gp.pangps" \
    "$gpGui/com.paloaltonetworks.gp.pangpa" \
    system/com.paloaltonetworks.gp.pangpsd; do
    gpDomain="${gpTarget%/*}"
    gpLabel="${gpTarget##*/}"
    if gpInfo=$(/bin/launchctl print "$gpTarget" 2>/dev/null); then
      gpInfo=$(print -r -- "$gpInfo" | /usr/bin/awk '
        /^[[:space:]]*state =/ && !state { state=$3 }
        /^[[:space:]]*pid =/ && !pid { pid=$3 }
        END { printf "已加载，state=%s", state; if (pid) printf "，pid=%s", pid }
      ')
    else
      gpInfo='未加载'
    fi
    if gpDisabled=$(/bin/launchctl print-disabled "$gpDomain" 2>/dev/null); then
      if [[ "$gpDisabled" == *"\"$gpLabel\" => disabled"* || "$gpDisabled" == *"\"$gpLabel\" => true"* ]]; then
        gpDisableText='已禁用自动加载'
      else
        gpDisableText='未显式禁用自动加载'
      fi
    else
      gpDisableText='无法查询禁用状态'
    fi
    print -- "${gpTarget}：${gpInfo}；${gpDisableText}"
  done
  print -- '相关进程（服务状态不等于 VPN 连接状态）：'
  /usr/bin/pgrep -xl 'PanGPS|GlobalProtect' || print -- '无'
}

# --- 网络选择 ---

GP_WIFI_IFACE='en0'

_gp-terminal-text() {
  local gpStyle
  if [[ ! -t 2 || "${TERM:-dumb}" == dumb || -n "${NO_COLOR:-}" ]]; then
    printf '%s' "$2"
    return
  fi
  case "$1" in
    brand)
      case "${ASHLEY_VPN_TERMINAL_PROFILE:-}:${COLORTERM:-}:${TERM:-}" in
        1:*) gpStyle='1;91' ;;
        *:truecolor:*|*:24bit:*) gpStyle='1;38;2;215;119;87' ;;
        *:*:*256color*) gpStyle='1;38;5;173' ;;
        *) gpStyle='1;33' ;;
      esac
      ;;
    heading)  gpStyle='1' ;;
    success)  gpStyle='1;32' ;;
    warning)  gpStyle='1;33' ;;
    error)    gpStyle='1;31' ;;
    muted)    gpStyle='2' ;;
  esac
  printf '\033[%sm%s\033[0m' "${gpStyle:-0}" "$2"
}

_gp-terminal-banner() {
  local columns="$1" availability
  availability=$(ashley_release_status "${ashley_running_version:-}" "${ashley_running_build:-}" "$ASHLEY_VPN_STATE")
  ashley_welcome_panel "${ashley_running_version:-}" "$availability" "$columns"
}

_gp-terminal-title() {
  local columns=0
  if [[ -t 2 && "${TERM:-dumb}" != dumb ]]; then columns=$(ashley_terminal_columns); fi
  {
    _gp-terminal-banner "$columns"
    _gp-terminal-text heading "  $1"
    printf '\n'
  } >&2
}

_gp-terminal-input-heading() {
  [[ "${ASHLEY_VPN_TERMINAL_PROFILE:-}" == 1 ]] || return 0
  [[ "${TERM:-dumb}" == dumb ]] || printf '\033[H\033[2J' >&2
  _gp-terminal-title "$1"
}

_gp-terminal-fit() {
  local gpText="$1" gpWidth="$2"
  if (( gpWidth < 1 )); then
    return 0
  elif (( ${(m)#gpText} > gpWidth )); then
    (( gpWidth-- ))
    if (( gpWidth == 0 )); then printf '…'; else printf '%s…' "${(mr:$gpWidth:)gpText}"; fi
  else
    printf '%s' "$gpText"
  fi
}

_gp-terminal-message() {
  {
    _gp-terminal-text "$1" "  $2"
    printf '  %s\n' "$3"
  } >&2
}

_gp-net-interfaces() {
  emulate -L zsh
  LC_ALL=C /usr/sbin/networksetup -listallhardwareports 2>/dev/null | /usr/bin/awk -v kind="$1" '
    /^Hardware Port: / { wifi = ($0 ~ /^Hardware Port: (Wi-Fi|AirPort)$/) }
    /^Device: en[0-9]+$/ && ((kind == "wifi") == wifi) { print $2 }
  '
}

_gp-net-interface-active() {
  LC_ALL=C /sbin/ifconfig "$1" 2>/dev/null | /usr/bin/grep -q '^[[:space:]]*status: active$'
}

_gp-net-wired-ready() {
  emulate -L zsh
  local gpPorts gpRoutes gpInterface
  gpPorts=$(_gp-net-interfaces wired)
  [[ -n "$gpPorts" ]] || return 1
  gpRoutes=$(LC_ALL=C /usr/sbin/netstat -rn 2>/dev/null) || return 1
  for gpInterface in ${(f)gpPorts}; do
    if /usr/bin/awk -v dev="$gpInterface" '
         $1 == "default" && $3 ~ /^U.*G/ && $4 == dev { found = 1 }
         END { exit !found }
       ' <<< "$gpRoutes" &&
       _gp-net-interface-active "$gpInterface"; then
      return 0
    fi
  done
  return 1
}

_gp-net-system-vpn-connected() {
  emulate -L zsh
  LC_ALL=C /usr/sbin/scutil --nc list 2>/dev/null | /usr/bin/awk '
    /^[[:space:]]*(\*[[:space:]]+)?\(Connected\)[[:space:]]/ &&
      tolower($0) !~ /paloaltonetworks|globalprotect/ { connected = 1 }
    END { exit !connected }
  '
}

gp-check-connect-network() {
  emulate -L zsh
  local gpInterface
  if ! _gp-net-wired-ready || ! _gp-net-system-vpn-connected; then
    return 0
  fi
  for gpInterface in ${(f)"$(_gp-net-interfaces wifi)"}; do
    if _gp-net-interface-active "$gpInterface"; then
      return 0
    fi
  done
  print -ru2 -- '当前仅有线网络已连接，且 macOS 系统 VPN 正在运行。'
  print -ru2 -- '请在「系统设置 → VPN」手动关闭系统 VPN，再重新开启集团 VPN。'
  return 1
}

_gp-scan-wifi() {
  emulate -L zsh
  local gpScanDir gpApp="${ASHLEY_VPN_RESOURCES:h:h}"
  gpScanDir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ashley-wifi-scan.XXXXXX") || return
  {
    _gp-progress-run '正在扫描附近的 Wi-Fi' /usr/bin/open -g -n -W -a "$gpApp" --args \
      --scan-wifi "$GP_WIFI_IFACE" "$gpScanDir/networks" || return
    [[ -r "$gpScanDir/networks" ]] && /bin/cat -- "$gpScanDir/networks"
  } always {
    /bin/rm -r -- "$gpScanDir"
  }
}

_gp-wifi-read-key() {
  emulate -L zsh
  local gpPrefix gpByte
  IFS= read -rsk 1 -t 0.25 -u 0 gpKey || return
  [[ "$gpKey" == $'\e' ]] || return 0
  # Escape alone cancels; arrow keys start with Escape and send a sequence.
  IFS= read -rsk 1 -t 0.08 -u 0 gpPrefix || return 0
  gpKey=''
  [[ "$gpPrefix" == '[' || "$gpPrefix" == O ]] || return 0
  for gpByte in {1..8}; do
    IFS= read -rsk 1 -t 0.08 -u 0 gpPrefix || return 0
    case "$gpPrefix" in
      A|B) gpKey=$'\e['"$gpPrefix"; return 0 ;;
      [[:alpha:]~]) return 0 ;;
    esac
  done
}

_gp-wifi-row() {
  local width="$1" framed="$2" text
  shift 2
  if [[ "$framed" == true ]]; then
    _gp-terminal-text brand '  │'
    printf ' '
  else
    printf '  '
  fi
  while (( $# >= 2 && width > 0 )); do
    text="$2"
    (( ${(m)#text} <= width )) || text=$(_gp-terminal-fit "$text" "$width")
    _gp-terminal-text "$1" "$text"
    (( width -= ${(m)#text} ))
    shift 2
  done
  if [[ "$framed" == true ]]; then
    printf '%*s' "$((width + 1))" ''
    _gp-terminal-text brand '│'
  fi
  printf '\n'
}

_gp-wifi-picker() {
  emulate -L zsh
  local gpCurrent="$1" gpKeep="$2" gpFallback="$3" gpMode="$4"
  shift 4
  local -a gpNetworks=("$@") gpVisible
  local gpKey gpName gpLabel gpQuery='' gpSearch=false gpCount gpKeepRow gpScanRow gpHiddenRow
  local gpIndex gpSelected=1 gpFirst=1 gpLast gpLimit gpTerminal gpInterrupted=false
  local gpViewport gpReleaseSnapshot gpLatestSnapshot
  local gpRows gpColumns gpWidth gpLabelWidth gpMarker gpTone gpBadge gpFooter gpRule=''
  local gpFramed gpTitle gpTopWidth gpBottomWidth gpBannerColumns gpBannerRows gpAction='选择 Wi-Fi'
  [[ "$gpMode" != disconnect ]] || gpAction='切换 Wi-Fi'

  # Draw on the alternate screen so ending the picker restores the operation log.
  gpTerminal=$(/bin/stty -g) || return 1
  {
    trap 'gpInterrupted=true' INT
    /bin/stty -echo -icanon min 1 time 0 || return 1
    printf '\e[?1049h\e[?25l' >&2
    while true; do
      gpVisible=()
      for gpName in "${gpNetworks[@]}"; do
        [[ "${(L)gpName}" == *"${(L)gpQuery}"* ]] && gpVisible+=("$gpName")
      done
      gpCount=${#gpVisible}
      gpKeepRow=0 gpScanRow=0 gpHiddenRow=0
      if [[ "$gpSearch" == false && -z "$gpQuery" ]]; then
        if [[ "$gpKeep" == true ]]; then
          gpVisible+=('保留当前网络')
          gpKeepRow=${#gpVisible}
        fi
        gpVisible+=('重新扫描' '输入隐藏网络名称')
        gpHiddenRow=${#gpVisible}
        gpScanRow=$(( gpHiddenRow - 1 ))
      fi
      (( gpSelected = gpSelected > ${#gpVisible} ? ${#gpVisible} : gpSelected ))
      (( gpSelected = gpSelected < 1 ? 1 : gpSelected ))
      gpViewport=$(/bin/stty size)
      { IFS= read -r gpReleaseSnapshot < "$ASHLEY_VPN_STATE/latest-release"; } 2>/dev/null || gpReleaseSnapshot=''
      read -r gpRows gpColumns <<< "$gpViewport"
      (( gpColumns != 0 )) || gpColumns=76
      gpBannerColumns=$gpColumns gpBannerRows=3
      if (( gpRows != 0 && gpRows < 17 )); then
        gpBannerColumns=0
      elif (( gpColumns >= 68 )); then
        gpBannerRows=8
      elif (( gpColumns >= 36 )); then
        gpBannerRows=4
      fi
      gpFramed=false
      if (( gpColumns >= 42 && (gpRows == 0 || gpRows >= 9) )); then
        gpFramed=true
        (( gpWidth = gpColumns - 8 ))
      else
        (( gpWidth = gpColumns > 12 ? gpColumns - 4 : 8 ))
      fi
      (( gpWidth = gpWidth > 66 ? 66 : gpWidth ))
      (( gpLimit = gpRows > 0 ? gpRows - 7 - gpBannerRows : 10 ))
      (( gpLimit = gpLimit < 1 ? 1 : gpLimit > 10 ? 10 : gpLimit ))
      (( gpSelected < gpFirst )) && gpFirst=$gpSelected
      (( gpSelected >= gpFirst + gpLimit )) && gpFirst=$(( gpSelected - gpLimit + 1 ))
      (( gpLast = gpFirst + gpLimit - 1 > ${#gpVisible} ? ${#gpVisible} : gpFirst + gpLimit - 1 ))

      {
        printf '\e[H\e[J'
        _gp-terminal-banner "$gpBannerColumns"
        if [[ "$gpFramed" == true ]]; then
          gpTitle="╭── $gpAction "
          gpTopWidth=$((gpWidth + 3 - ${(m)#gpTitle}))
          _gp-terminal-text brand "  $gpTitle${(l:$gpTopWidth::─:)gpRule}╮"
          printf '\n'
        else
          _gp-wifi-row "$gpWidth" false heading "$gpAction"
        fi
        if [[ "$gpSearch" == true ]]; then
          _gp-wifi-row "$gpWidth" "$gpFramed" heading '搜索  ' normal "$gpQuery▏"
        elif [[ -n "$gpQuery" ]]; then
          _gp-wifi-row "$gpWidth" "$gpFramed" muted '筛选  ' normal "$gpQuery"
        elif [[ "$gpFallback" == true ]]; then
          _gp-wifi-row "$gpWidth" "$gpFramed" muted '已保存的网络'
        fi
        if (( gpLast < gpFirst )); then
          _gp-wifi-row "$gpWidth" "$gpFramed" muted '找不到匹配的网络'
        fi
        for (( gpIndex = gpFirst; gpIndex <= gpLast; gpIndex++ )); do
          gpLabel=$gpVisible[gpIndex]
          gpMarker=' ' gpTone=normal gpBadge=''
          (( gpIndex > gpCount )) && gpTone=muted
          if (( gpIndex <= gpCount && gpWidth >= 18 )) && [[ "$gpLabel" == "$gpCurrent" ]]; then
            gpBadge='  ● 当前'
          fi
          if (( gpIndex == gpSelected )); then
            gpMarker='❯' gpTone=heading
          fi
          gpLabelWidth=$((gpWidth - 2 - ${(m)#gpBadge}))
          (( ${(m)#gpLabel} <= gpLabelWidth )) || gpLabel=$(_gp-terminal-fit "$gpLabel" "$gpLabelWidth")
          _gp-wifi-row "$gpWidth" "$gpFramed" brand "$gpMarker " "$gpTone" "$gpLabel" success "$gpBadge"
        done
        if (( ${#gpVisible} > gpLimit )); then
          _gp-wifi-row "$gpWidth" "$gpFramed" muted "$gpFirst–$gpLast / ${#gpVisible}"
        fi
        _gp-wifi-row "$gpWidth" "$gpFramed" muted "${(l:$gpWidth::─:)gpRule}"
        if [[ "$gpSearch" == true || -n "$gpQuery" ]]; then
          gpFooter='↑↓ 选择  ↵ 确认  Esc 清除'
        else
          gpFooter='↑↓ 选择  ↵ 确认  Tab 搜索  Esc 取消'
          (( ${(m)#gpFooter} <= gpWidth )) || gpFooter='↑↓  ↵  Tab 搜索  Esc 取消'
        fi
        (( ${(m)#gpFooter} <= gpWidth )) || gpFooter='↑↓ ↵ Tab Esc'
        _gp-wifi-row "$gpWidth" "$gpFramed" muted "$gpFooter"
        if [[ "$gpFramed" == true ]]; then
          gpBottomWidth=$((gpWidth + 2))
          _gp-terminal-text brand "  ╰${(l:$gpBottomWidth::─:)gpRule}╯"
          printf '\n'
        fi
      } >&2

      until _gp-wifi-read-key; do
        [[ "$gpInterrupted" == true ]] && return 130
        [[ "$(/bin/stty size)" != "$gpViewport" ]] && continue 2
        { IFS= read -r gpLatestSnapshot < "$ASHLEY_VPN_STATE/latest-release"; } 2>/dev/null || gpLatestSnapshot=''
        [[ "$gpLatestSnapshot" != "$gpReleaseSnapshot" ]] && continue 2
      done
      [[ "$gpInterrupted" == true ]] && return 130
      case "$gpKey" in
        $'\e[A') (( gpSelected > 1 )) && (( gpSelected-- )) ;;
        $'\e[B') (( gpSelected < ${#gpVisible} )) && (( gpSelected++ )) ;;
        $'\t')
          if [[ "$gpSearch" == true ]]; then
            gpSearch=false
          else
            gpSearch=true
          fi
          ;;
        $'\e')
          if [[ "$gpSearch" == false && -z "$gpQuery" ]]; then
            return 1
          fi
          gpSearch=false gpQuery='' gpSelected=1 gpFirst=1
          ;;
        $'\r'|$'\n')
          if (( gpSelected == gpKeepRow )); then
            REPLY=''
            return 0
          fi
          (( gpSelected == gpScanRow )) && return 2
          (( gpSelected == gpHiddenRow )) && return 3
          if (( gpSelected <= gpCount )); then
            REPLY="$gpVisible[gpSelected]"
            return 0
          fi
          ;;
        $'\177'|$'\b')
          if [[ "$gpSearch" == true && -n "$gpQuery" ]]; then
            gpQuery=${gpQuery[1,-2]} gpSelected=1 gpFirst=1
          fi
          ;;
        [[:print:]])
          if [[ "$gpSearch" == true && ${#gpQuery} -lt 32 ]]; then
            gpQuery+="$gpKey"
            gpSelected=1 gpFirst=1
          fi
          ;;
      esac
    done
  } always {
    /bin/stty "$gpTerminal"
    printf '\e[?25h\e[?1049l' >&2
  }
}

_gp-select-wifi() {
  emulate -L zsh
  [[ -t 0 && -t 2 ]] || return 1
  REPLY=''
  local gpMode="$1" gpFound gpName gpCurrent gpInput gpFallback gpKeep gpResult
  local -a gpPinned
  local -aU gpNetworks gpOrdered
  if [[ "$gpMode" == disconnect ]]; then
    gpPinned=(OfficeWiFi officewifi)
  else
    gpPinned=(officewifi OfficeWiFi)
  fi

  while true; do
    gpCurrent='' gpKeep=false
    [[ "$gpMode" == disconnect ]] && gpKeep=true
    if _gp-net-interface-active "$GP_WIFI_IFACE"; then
      gpKeep=true
      gpCurrent=$(gp-net-current-ssid)
      [[ "$gpCurrent" == '<redacted>' ]] && gpCurrent=''
    fi
    gpFallback=false
    if ! gpFound=$(_gp-scan-wifi) || [[ -z "$gpFound" ]]; then
      gpFound=$(LC_ALL=C /usr/sbin/networksetup -listpreferredwirelessnetworks "$GP_WIFI_IFACE" 2>/dev/null |
        /usr/bin/awk 'NR > 1 { sub(/^\t/, ""); print }')
      gpFallback=true
    fi
    gpNetworks=()
    for gpName in "$gpCurrent" "${(@f)gpFound}"; do
      [[ -n "$gpName" && "$gpName" != *[[:cntrl:]]* ]] && gpNetworks+=("$gpName")
    done
    gpOrdered=()
    for gpName in "${gpPinned[@]}" "${(@oi)gpNetworks}"; do
      (( ${gpNetworks[(Ie)$gpName]} )) && gpOrdered+=("$gpName")
    done

    if [[ "$ASHLEY_VPN_BACKGROUND" == 1 ]]; then
      if [[ "$gpMode" == disconnect ]]; then
        _gp-gui-progress 'VPN 已关闭，请在终端选择 Wi-Fi'
      else
        _gp-gui-progress '请在终端选择 Wi-Fi'
      fi
    fi
    while true; do
      gpResult=0
      _gp-wifi-picker "$gpCurrent" "$gpKeep" "$gpFallback" "$gpMode" "${gpOrdered[@]}" || gpResult=$?
      case "$gpResult" in
        2) break ;;
        3)
          _gp-terminal-input-heading '输入隐藏网络名称'
          _gp-terminal-message brand '›' '完整 Wi-Fi 名称区分大小写，直接回车返回。'
          printf '  Wi-Fi 名称：' >&2
          IFS= read -r gpInput || return 1
          if [[ -n "$gpInput" ]]; then
            REPLY="$gpInput"
            return 0
          fi
          ;;
        *) return "$gpResult" ;;
      esac
    done
  done
}

gp-disconnect() {
  emulate -L zsh
  local gpProgressStep='1/2'
  [[ "$ASHLEY_VPN_BACKGROUND" != 1 ]] || _gp-gui-progress '正在关闭集团 VPN'
  gp-stop || return
  gpProgressStep='2/2'
  [[ "$ASHLEY_VPN_BACKGROUND" != 1 ]] || _gp-gui-progress 'VPN 已关闭，正在检查网络'
  if _gp-net-wired-ready; then
    print -r -- '检测到有线网络，保留当前网络设置。'
  elif _gp-net-system-vpn-connected; then
    print -r -- '检测到 macOS 系统 VPN 已连接，保留当前网络设置。'
  elif [[ -z "$(_gp-net-interfaces wifi | /usr/bin/head -n 1)" ]]; then
    print -r -- '这台 Mac 没有可用的 Wi-Fi 接口，已结束关闭流程。'
  elif [[ "$ASHLEY_VPN_BACKGROUND" == 1 && ! -t 0 ]]; then
    _gp-terminal-input disconnect-wifi
  else
    _gp-disconnect-wifi
  fi
}

_gp-disconnect-wifi() {
  emulate -L zsh
  local GP_WIFI_IFACE REPLY gpSelection=0
  GP_WIFI_IFACE=$(_gp-net-interfaces wifi | /usr/bin/head -n 1)
  [[ -n "$GP_WIFI_IFACE" ]] || return 0
  _gp-select-wifi disconnect || gpSelection=$?
  (( gpSelection == 130 )) && return 130
  if (( gpSelection != 0 )) || [[ -z "$REPLY" ]]; then
    print -r -- 'VPN 已关闭，保留当前网络设置。'
  elif ! wifi-switch "$REPLY"; then
    print -ru2 -- 'VPN 已关闭，Wi-Fi 切换未完成。'
    return 1
  fi
}

gp-net-current-ssid() {
  emulate -L zsh
  local gpSsid
  gpSsid=$(/usr/sbin/ipconfig getsummary "$GP_WIFI_IFACE" 2>/dev/null \
    | /usr/bin/sed -n 's/^[[:space:]]*SSID : //p' | /usr/bin/head -n 1)
  if [[ -z "$gpSsid" || "$gpSsid" == '<redacted>' ]]; then
    # ipconfig 可能因缺少定位权限输出 <redacted>,退回 networksetup 查询。
    gpSsid=$(/usr/sbin/networksetup -getairportnetwork "$GP_WIFI_IFACE" 2>/dev/null \
      | /usr/bin/sed -n 's/^Current Wi-Fi Network: //p' | /usr/bin/head -n 1)
  fi
  print -r -- "${gpSsid:-}"
}

_gp-net-online() {
  emulate -L zsh
  /usr/bin/curl -m 3 -s -o /dev/null http://captive.apple.com
}

gp-net-current() {
  emulate -L zsh
  local gpSsid gpOnline='no'
  gpSsid=$(gp-net-current-ssid)
  _gp-net-online && gpOnline='yes'
  print -r -- "ssid=${gpSsid:-none} online=$gpOnline"
}

_gp-wifi-join() {
  emulate -L zsh
  local gpSsid="$1" gpResult gpStatus
  shift
  # networksetup can print a join error and still exit zero. A lone "-" reads
  # the password from stdin instead of exposing it in the process arguments.
  if [[ "$1" == saved ]]; then
    gpResult=$(LC_ALL=C "$ASHLEY_VPN_RESOURCES/wifi-keychain" join "$gpSsid" "$GP_WIFI_IFACE" 2>&1)
    gpStatus=$?
    # No credential means no association was attempted.
    (( gpStatus != 44 )) || return 4
  else
    gpResult=$(LC_ALL=C /usr/sbin/networksetup -setairportnetwork "$GP_WIFI_IFACE" "$gpSsid" "$@" 2>&1)
    gpStatus=$?
  fi
  if (( gpStatus != 0 )) || [[ -n "$gpResult" ]]; then
    case ${(L)gpResult} in
      *-3958*|*-3905*|*'timed out'*) return 3 ;;
      *-3900*|*password*|*authentication*) return 2 ;;
      *) return 1 ;;
    esac
  fi
  # The join command can succeed before macOS reports the new SSID or route.
  # Confirm the requested network in _gp-net-wait-wifi instead of re-prompting.
  return 0
}

_gp-wifi-join-retry() {
  emulate -L zsh
  local gpTry gpStatus
  for gpTry in 1 2 3; do
    _gp-wifi-join "$@"
    gpStatus=$?
    (( gpStatus == 3 && gpTry < 3 )) || return "$gpStatus"
    print -u2 -- "正在重试连接 $1（第 $((gpTry + 1)) 次）…"
    /bin/sleep "$gpTry"
  done
}

_gp-wifi-join-default() {
  emulate -L zsh
  _gp-wifi-join-retry "$1" saved
  local gpStatus=$?
  if (( gpStatus == 4 )); then
    _gp-wifi-join-retry "$1"
  else
    return "$gpStatus"
  fi
}

wifi-switch() {
  emulate -L zsh
  unsetopt xtrace
  local gpSsid="$1" gpCur gpPassword gpStatus gpPrompt
  local gpKeychain="$ASHLEY_VPN_RESOURCES/wifi-keychain"
  if [[ -z "$gpSsid" || "$gpSsid" == *[[:cntrl:]]* ]] ||
     ! (LC_ALL=C; (( ${#gpSsid} <= 32 ))); then
    print -ru2 -- 'Wi-Fi 名称须为 1–32 字节且不含控制字符。'
    return 1
  fi
  gpCur=$(gp-net-current-ssid)
  if [[ "$gpCur" == "$gpSsid" ]] && _gp-net-interface-active "$GP_WIFI_IFACE"; then
    _gp-progress-run "正在确认 $gpSsid 网络就绪" _gp-net-wait-wifi "$gpSsid" || return
    print -r -- "当前已在 $gpSsid。"
    return 0
  fi
  _gp-progress-run "正在加入 $gpSsid" _gp-wifi-join-default "$gpSsid"
  gpStatus=$?
  if (( gpStatus == 0 )); then
    _gp-progress-run "正在确认 $gpSsid 网络就绪" _gp-net-wait-wifi "$gpSsid" || return
    print -r -- "已加入 $gpSsid。"
    return 0
  fi
  if (( gpStatus == 3 )); then
    print -u2 -- "重试后 $gpSsid 仍未就绪，请查看系统 Wi-Fi。"
    return 1
  fi

  if (( gpStatus != 2 )); then
    print -u2 -- "未能加入 $gpSsid，请在 Wi-Fi 菜单确认网络可用。"
    return 1
  fi

  if [[ ! -t 0 || ! -t 2 ]]; then
    print -u2 -- "$gpSsid 需要 Wi-Fi 密码。请在终端运行 wifi-switch $gpSsid，连接成功后会记住密码。"
    return 1
  fi
  _gp-terminal-input-heading '输入 Wi-Fi 密码'
  _gp-terminal-message brand '›' "Wi-Fi  $gpSsid"
  _gp-terminal-message muted '·' '密码输入时不回显，直接回车取消。'
  gpPrompt=$(_gp-terminal-text heading '  Wi-Fi 密码：')
  while true; do
    gpPassword=''
    [[ "$ASHLEY_VPN_BACKGROUND" != 1 ]] || _gp-gui-progress '请在终端输入 Wi-Fi 密码'
    if ! IFS= read -rs "gpPassword?$gpPrompt"; then
      print -ru2 -- ''
      return 130
    fi
    print -ru2 -- ''
    [[ -n "$gpPassword" ]] || return 130
    gpStatus=0
    print -r -- "$gpPassword" | _gp-progress-run "正在验证 Wi-Fi 密码并加入 $gpSsid" _gp-wifi-join "$gpSsid" - || gpStatus=$?
    (( gpStatus == 0 )) && break
    case "$gpStatus" in
      2) _gp-terminal-message error '✕' 'Wi-Fi 密码验证失败，请重新输入。' ;;
      3) _gp-terminal-message warning '!' "连接 $gpSsid 超时，请核对密码后重试。" ;;
      *) _gp-terminal-message error '✕' "未能加入 $gpSsid，请确认网络可用后重试。" ;;
    esac
  done
  _gp-progress-run "正在确认 $gpSsid 网络就绪" _gp-net-wait-wifi "$gpSsid" || return
  _gp-terminal-message success '✓' "已加入 $gpSsid。"
  if ! print -rn -- "$gpPassword" | "$gpKeychain" save "$gpSsid"; then
    _gp-terminal-message warning '!' 'Wi-Fi 已连接，但密码未能保存到本机钥匙串。'
  fi
  return 0
}

_gp-net-wait-wifi() {
  emulate -L zsh
  local gpSsid="$1" gpAttempt gpCur gpReady=0
  for gpAttempt in {1..30}; do
    gpCur=$(gp-net-current-ssid)
    if ! _gp-net-interface-active "$GP_WIFI_IFACE" ||
       [[ -n "$gpSsid" && -n "$gpCur" && "$gpCur" != '<redacted>' && "$gpCur" != "$gpSsid" ]]; then
      gpReady=0
    elif _gp-wifi-route-ready; then
      (( ++gpReady >= 2 )) && return 0
    else
      gpReady=0
    fi
    /bin/sleep 1
  done
  print -u2 -- "${gpSsid:-当前 Wi-Fi} 的连接尚未确认，或 Wi-Fi 尚未获得可用的网络路由。"
  return 1
}

_gp-wifi-route-ready() {
  local gpFamily
  if /usr/sbin/ipconfig getifaddr "$GP_WIFI_IFACE" >/dev/null 2>&1 &&
     /usr/sbin/ipconfig getoption "$GP_WIFI_IFACE" router >/dev/null 2>&1; then
    return 0
  fi
  for gpFamily in -inet -inet6; do
    if /sbin/route -n get "$gpFamily" -ifscope "$GP_WIFI_IFACE" default 2>/dev/null |
       /usr/bin/awk -v interface="$GP_WIFI_IFACE" '$1 == "interface:" && $2 == interface { found=1 } END { exit !found }'; then
      return 0
    fi
  done
  return 1
}

_gp-vpn-log-state() {
  emulate -L zsh
  local gpPid="$1" gpStarted="$2"
  shift 2
  LC_ALL=C /usr/bin/awk -v pid="$gpPid" -v since="$gpStarted" '
    BEGIN { prefix = "^P[[:space:]]*" pid "-T[0-9]+[[:space:]]+" }
    $0 ~ prefix {
      line = $0
      sub(prefix, "", line)
      split(line, fields, /[[:space:]]+/)
      split(fields[1], day, "/")
      split(fields[2], time, ":")
      stamp = day[3] day[1] day[2] time[1] time[2] time[3]
      if (length(stamp) != 14 || stamp < since) next
      # Some GlobalProtect versions add ellipses to state names.
      sub(/[.[:space:]]+$/, "", line)
      if (line ~ /: VPN tunnel is connected$/) {
        tunnel = 1
        state = "verifying"
      } else if (line ~ /: Tunnel down([.]|time is [0-9]+ miliseconds)?[[:space:]]*$/) {
        tunnel = 0
        state = "waiting"
      } else if (line ~ /--Set state to Connected[[:space:]]*$/) {
        state = tunnel ? "connected" : "verifying"
      } else if (line ~ /--Set state to Connection failed[[:space:]]*$/) {
        tunnel = 0
        state = "failed"
      } else if (line ~ /--Set state to (Disconnected|Disconnecting|disabled)[[:space:]]*$/) {
        tunnel = 0
        state = "waiting"
      } else if (line ~ /--Set state to (Retrieving configuration|Discovering network)[[:space:]]*$/) {
        tunnel = 0
        state = "configuration"
      } else if (line ~ /--Set state to (Connecting|Restoring VPN Connection)[[:space:]]*$/) {
        tunnel = 0
        state = "tunnel"
      } else if (line ~ /Gateway saml login|Portal saml login/) {
        state = "auth"
      }
    }
    END { print state ? state : "waiting" }
  ' "$@"
}

_gp-vpn-current-state() {
  emulate -L zsh
  local gpPid gpStartText gpStarted
  local gpLog=/Library/Logs/PaloAltoNetworks/GlobalProtect/PanGPS.log
  local -a gpLogs
  gpPid=$(/usr/bin/pgrep -x PanGPS) || return 1
  [[ -n "$gpPid" && "$gpPid" != *[^0-9]* ]] || return 1
  # Both sides must use the same locale for weekday and month names.
  gpStartText=$(LC_ALL=C /bin/ps -p "$gpPid" -o lstart= | /usr/bin/awk '{$1=$1; print}')
  gpStarted=$(LC_ALL=C /bin/date -j -f '%a %b %e %T %Y' "$gpStartText" '+%Y%m%d%H%M%S' 2>/dev/null) || return 1
  [[ -r "${gpLog:r}.1.log" ]] && gpLogs+=("${gpLog:r}.1.log")
  [[ -r "$gpLog" ]] && gpLogs+=("$gpLog")
  (( ${#gpLogs} )) || return 1
  _gp-vpn-log-state "$gpPid" "$gpStarted" "${gpLogs[@]}"
}

_gp-wait-vpn() {
  emulate -L zsh
  local gpTimeout="${1:-120}" gpStart="$SECONDS" gpElapsed gpState gpLast='' gpLabel
  local -a gpFrames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local gpStatus=1 gpLastTick=-10
  [[ "$ASHLEY_VPN_BACKGROUND" == 1 ]] ||
    print -r -- '正在等待 VPN 建立连接。如 GlobalProtect 弹出登录窗口，请在那里完成验证。'
  {
    while (( SECONDS - gpStart < gpTimeout )); do
      gpElapsed=$((SECONDS - gpStart))
      gpState=$(_gp-vpn-current-state) || gpState=waiting
      case "$gpState" in
        connected) gpStatus=0; break ;;
        auth) gpLabel='正在等待身份验证' ;;
        configuration) gpLabel='正在获取配置并检测网络' ;;
        tunnel) gpLabel='正在建立 VPN 隧道' ;;
        verifying) gpLabel='正在确认 VPN 隧道状态' ;;
        failed) gpLabel='客户端报告连接失败，等待客户端重试' ;;
        *) gpLabel='正在等待 GlobalProtect 连接' ;;
      esac
      if [[ "$ASHLEY_VPN_BACKGROUND" == 1 ]]; then
        _gp-gui-progress "$gpLabel" "$((gpTimeout - gpElapsed))"
      elif [[ -t 2 ]]; then
        printf >&2 '\r\033[2K%s %s… %s 秒' "${gpFrames[$((gpElapsed % ${#gpFrames} + 1))]}" "$gpLabel" "$gpElapsed"
      elif [[ "$gpState" != "$gpLast" ]] || (( gpElapsed - gpLastTick >= 10 )); then
        print -ru2 -- "$gpLabel… $gpElapsed 秒"
        gpLastTick="$gpElapsed"
      fi
      gpLast="$gpState"
      /bin/sleep 1
    done
  } always {
    [[ "$ASHLEY_VPN_BACKGROUND" == 1 || ! -t 2 ]] || printf >&2 '\r\033[2K'
  }
  if (( gpStatus == 0 )); then
    print -r -- "VPN 已连接，隧道已建立（等待 $((SECONDS - gpStart)) 秒）。"
    return 0
  fi
  print -ru2 -- "等待 ${gpTimeout} 秒后仍未确认 VPN 隧道建立。请在 GlobalProtect 查看连接或登录状态。"
  return 1
}

_gp-reset-first-connection() {
  if [[ "$1" == reset ]] && ! _gp-already-stopped; then
    print -r -- '首次连接前检测到 GlobalProtect 正在运行，正在关闭现有服务…'
    gp-stop || return
  fi
}

_gp-connect-wifi() {
  emulate -L zsh
  local GP_WIFI_IFACE REPLY gpSsid
  GP_WIFI_IFACE=$(_gp-net-interfaces wifi | /usr/bin/head -n 1)
  if [[ -z "$GP_WIFI_IFACE" ]]; then
    print -ru2 -- '没有可用的有线网络或 Wi-Fi 接口，无法启动 GlobalProtect。'
    return 1
  fi
  _gp-select-wifi connect || return 130
  gpSsid="$REPLY"
  _gp-reset-first-connection "${1:-}" || return
  if [[ -n "$gpSsid" ]]; then
    wifi-switch "$gpSsid"
  else
    _gp-progress-run '正在确认当前 Wi-Fi 网络就绪' _gp-net-wait-wifi ''
  fi
}

gp-connect() {
  emulate -L zsh
  local gpMode=connect-wifi gpProgressStep='1/3'
  [[ "$ASHLEY_VPN_BACKGROUND" != 1 ]] || _gp-gui-progress '正在准备连接集团 VPN'
  if _gp-net-wired-ready; then
    print -r -- '检测到有线网络已就绪，无需选择 Wi-Fi。'
    _gp-reset-first-connection "${1:-}" || return
  elif [[ "$ASHLEY_VPN_BACKGROUND" == 1 && ! -t 0 ]]; then
    [[ "$1" != reset ]] || gpMode=connect-wifi-reset
    _gp-terminal-input "$gpMode" || return
  else
    _gp-connect-wifi "${1:-}" || return
  fi
  gpProgressStep='2/3'
  [[ "$ASHLEY_VPN_BACKGROUND" != 1 ]] || _gp-gui-progress '网络已就绪，正在启动 GlobalProtect'
  print -r -- '网络已就绪，正在启动 GlobalProtect…'
  gp-start || return
  gpProgressStep='3/3'
  _gp-wait-vpn
}
