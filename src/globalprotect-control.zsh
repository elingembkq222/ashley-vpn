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
    _gp-start-service system com.paloaltonetworks.gp.pangpsd \
      /Library/LaunchDaemons/com.paloaltonetworks.gp.pangpsd.plist || return
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
  local gpOutput gpStatus
  local gpInstaller="$ASHLEY_VPN_RESOURCES/setup-stop-authorization.sh"
  local gpHelper=/private/etc/ashley-vpn-stop

  gpOutput=$(LC_ALL=C /usr/bin/sudo -kn -- "$gpHelper" check 2>&1)
  gpStatus=$?
  if (( gpStatus == 0 )); then
    return 0
  fi
  if (( gpStatus != 77 )) && [[ "$gpOutput" != 'sudo: a password is required' &&
      "$gpOutput" != "sudo: $gpHelper: command not found" ]]; then
    print -ru2 -- "$gpOutput"
    if [[ -t 2 ]]; then
      print -ru2 -- '无法检查停止授权。终端将在 12 秒后关闭。'
      /bin/sleep 12
    fi
    return "$gpStatus"
  fi
  if [[ ! -t 0 || ! -t 2 || ! -r "$gpInstaller" ]]; then
    print -u2 -- '请从菜单栏 Ashley VPN 选择「关闭 VPN」，并在终端完成 macOS 验证。'
    return 1
  fi

  print -r -- '本次安装首次关闭需验证一次本机密码，仅授权停用和卸载此 GlobalProtect 服务。'
  if /usr/bin/sudo -k -p '请输入本机管理员密码以授权停止 GlobalProtect：' -- /bin/sh "$gpInstaller" &&
     LC_ALL=C /usr/bin/sudo -kn -- "$gpHelper" check; then
    print -r -- '系统服务停止授权已确认。'
    return 0
  fi
  print -ru2 -- '停止授权未完成，请查看上方的 sudo 或系统提示。终端将在 12 秒后关闭。'
  /bin/sleep 12
  return 1
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
  print -r -- '正在关闭 GlobalProtect…'
  local gpGui="gui/$EUID"
  local gpSystemJob='system/com.paloaltonetworks.gp.pangpsd' gpSystemDisabled
  gpSystemDisabled=$(/bin/launchctl print-disabled system 2>/dev/null)
  # A disabled and unloaded system job needs no privileged changes.
  if { [[ "$gpSystemDisabled" != *'"com.paloaltonetworks.gp.pangpsd" => disabled'* ]] &&
       [[ "$gpSystemDisabled" != *'"com.paloaltonetworks.gp.pangpsd" => true'* ]]; } ||
     /bin/launchctl print "$gpSystemJob" >/dev/null 2>&1; then
    _gp-authorize-stop || return
    /usr/bin/sudo -kn -- /private/etc/ashley-vpn-stop disable || return
  fi
  _gp-launchctl "$gpGui" disable "$gpGui/com.paloaltonetworks.gp.pangpa" || return
  _gp-launchctl "$gpGui" disable "$gpGui/com.paloaltonetworks.gp.pangps" || return
  local gpTarget gpDomain gpUnloadAttempt gpBootout gpStep
  for gpTarget in \
    "$gpGui/com.paloaltonetworks.gp.pangpa" \
    "$gpGui/com.paloaltonetworks.gp.pangps" \
    "$gpSystemJob"; do
    gpDomain="${gpTarget%/*}"
    if /bin/launchctl print "$gpTarget" >/dev/null 2>&1; then
      case "$gpTarget" in
        */com.paloaltonetworks.gp.pangpa) gpStep='正在退出 GlobalProtect 界面' ;;
        *) gpStep='正在停止 GlobalProtect 服务并断开 VPN' ;;
      esac
      if [[ "$gpDomain" == system ]]; then
        _gp-progress-run "$gpStep" /usr/bin/sudo -kn -- /private/etc/ashley-vpn-stop bootout
      else
        _gp-progress-run "$gpStep" _gp-launchctl "$gpDomain" bootout "$gpTarget"
      fi
      gpBootout=$?
      if (( gpBootout != 0 )) && /bin/launchctl print "$gpTarget" >/dev/null 2>&1; then
        return "$gpBootout"
      fi
    fi
    # bootout may return before launchd finishes the configured exit timeout.
    for gpUnloadAttempt in {1..25}; do
      /bin/launchctl print "$gpTarget" >/dev/null 2>&1 || break
      (( gpUnloadAttempt == 1 || gpUnloadAttempt % 5 == 0 )) &&
        print -ru2 -- "正在等待 GlobalProtect 完成退出…"
      /bin/sleep 1
    done
    if /bin/launchctl print "$gpTarget" >/dev/null 2>&1; then
      print -u2 -- "服务卸载后仍可查询：$gpTarget"
      return 1
    fi
  done
  local gpAttempt
  for gpAttempt in {1..5}; do
    if ! /usr/bin/pgrep -x 'PanGPS|GlobalProtect' >/dev/null; then
      print -- '关闭完成：VPN 已断开，GlobalProtect 已停止。'
      return 0
    fi
    /bin/sleep 1
  done
  print -u2 -- '服务已卸载并禁用，但仍有 GlobalProtect/PanGPS 进程残留；未确认完全停止。'
  gp-status
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

# --- 自动切换网络(2026-11-16 新增) ---
# officewifi 用于连接集团 VPN，OfficeWiFi 是断开后可选的日常网络。

GP_VPN_WIFI='officewifi'
GP_HOME_WIFI='OfficeWiFi'
GP_WIFI_IFACE='en0'

_gp-net-wired-ready() {
  emulate -L zsh
  local gpPorts gpRoutes gpInterface
  gpPorts=$(LC_ALL=C /usr/sbin/networksetup -listallhardwareports 2>/dev/null | /usr/bin/awk '
    /^Hardware Port: / { wifi = ($0 ~ /^Hardware Port: (Wi-Fi|AirPort)$/) }
    /^Device: en[0-9]+$/ && !wifi { print $2 }
  ')
  [[ -n "$gpPorts" ]] || return 1
  gpRoutes=$(LC_ALL=C /usr/sbin/netstat -rn 2>/dev/null) || return 1
  for gpInterface in ${(f)gpPorts}; do
    if /usr/bin/awk -v dev="$gpInterface" '
         $1 == "default" && $3 ~ /^U.*G/ && $4 == dev { found = 1 }
         END { exit !found }
       ' <<< "$gpRoutes" &&
       LC_ALL=C /sbin/ifconfig "$gpInterface" 2>/dev/null | /usr/bin/grep -q '^[[:space:]]*status: active$'; then
      return 0
    fi
  done
  return 1
}

gp-disconnect() {
  emulate -L zsh
  gp-stop || return
  if _gp-net-wired-ready; then
    print -r -- '检测到有线网络，保留当前网络设置。'
  elif [[ "$(gp-net-current-ssid)" == "$GP_HOME_WIFI" ]]; then
    print -r -- "当前已在 $GP_HOME_WIFI。"
  elif [[ -r "$ASHLEY_VPN_STATE/home-wifi-profile" ]] ||
       LC_ALL=C /usr/sbin/networksetup -listpreferredwirelessnetworks "$GP_WIFI_IFACE" 2>/dev/null |
         /usr/bin/awk -v ssid="$GP_HOME_WIFI" '
           { sub(/^[[:space:]]+/, "") }
           $0 == ssid { found = 1 }
           END { exit !found }
         '; then
    if ! wifi-switch "$GP_HOME_WIFI"; then
      print -ru2 -- "VPN 已关闭，未切换到 $GP_HOME_WIFI。"
    fi
  else
    print -r -- "这台 Mac 未配置 $GP_HOME_WIFI，保留当前网络设置。"
  fi
  return 0
}

_gp-net-active-profile() {
  emulate -L zsh
  /usr/sbin/scutil <<EOF | /usr/bin/awk '
    $1 == "Active" && $2 == ":" && $3 == "TRUE" { active = 1 }
    $1 == "ProfileID" && $2 == ":" && length($3) == 64 && $3 !~ /[^0-9a-f]/ { profile = $3 }
    END { if (active && profile) print profile; else exit 1 }
  '
show State:/Network/Interface/$GP_WIFI_IFACE/Link
show State:/Network/Interface/$GP_WIFI_IFACE/AirPort
quit
EOF
}

_gp-net-store-home-profile() {
  emulate -L zsh
  local gpProfile="$1" gpTemp
  [[ "${#gpProfile}" == 64 && "$gpProfile" != *[^0-9a-f]* ]] || return 1
  umask 077
  gpTemp=$(/usr/bin/mktemp "$ASHLEY_VPN_STATE/.home-wifi-profile.XXXXXX") || return
  if ! print -r -- "$gpProfile" > "$gpTemp" ||
     ! /bin/mv -f "$gpTemp" "$ASHLEY_VPN_STATE/home-wifi-profile"; then
    /bin/rm -- "$gpTemp"
    return 1
  fi
}

gp-net-current-ssid() {
  emulate -L zsh
  local gpSsid gpHomeProfile gpProfile
  gpSsid=$(/usr/sbin/ipconfig getsummary "$GP_WIFI_IFACE" 2>/dev/null \
    | /usr/bin/sed -n 's/^[[:space:]]*SSID : //p' | /usr/bin/head -n 1)
  if [[ -z "$gpSsid" || "$gpSsid" == '<redacted>' ]]; then
    # ipconfig 可能因缺少定位权限输出 <redacted>,退回 networksetup 查询。
    gpSsid=$(/usr/sbin/networksetup -getairportnetwork "$GP_WIFI_IFACE" 2>/dev/null \
      | /usr/bin/sed -n 's/^Current Wi-Fi Network: //p' | /usr/bin/head -n 1)
  fi
  if [[ -z "$gpSsid" || "$gpSsid" == '<redacted>' ]]; then
    if { IFS= read -r gpHomeProfile < "$ASHLEY_VPN_STATE/home-wifi-profile"; } 2>/dev/null &&
       gpProfile=$(_gp-net-active-profile) && [[ "$gpProfile" == "$gpHomeProfile" ]]; then
      gpSsid="$GP_HOME_WIFI"
    fi
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
  local gpSsid="$1" gpResult gpStatus gpCur gpPriorProfile gpAssociatedProfile gpJoinedProfile
  shift
  if [[ "$gpSsid" == "$GP_HOME_WIFI" ]]; then
    gpPriorProfile=$(_gp-net-active-profile)
  fi
  # networksetup can print a join error and still exit zero. A lone "-" reads
  # the password from stdin instead of exposing it in the process arguments.
  if [[ "$1" == saved ]]; then
    gpResult=$(LC_ALL=C "$ASHLEY_VPN_RESOURCES/wifi-keychain" join "$gpSsid" 2>&1)
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
  gpCur=$(gp-net-current-ssid)
  [[ -z "$gpCur" || "$gpCur" == '<redacted>' || "$gpCur" == "$gpSsid" ]] || return 3
  if [[ "$gpSsid" == "$GP_HOME_WIFI" ]]; then
    gpAssociatedProfile=$(_gp-net-active-profile)
    _gp-net-wait-wifi "$gpSsid" || return 3
    if gpJoinedProfile=$(_gp-net-active-profile) &&
       [[ "$gpJoinedProfile" == "$gpAssociatedProfile" ]] &&
       [[ "$gpCur" == "$GP_HOME_WIFI" || "$gpJoinedProfile" != "$gpPriorProfile" ]]; then
      _gp-net-store-home-profile "$gpJoinedProfile"
    fi
  fi
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
  local gpSsid="$1" gpCur gpPassword gpStatus
  local gpKeychain="$ASHLEY_VPN_RESOURCES/wifi-keychain"
  if [[ "$gpSsid" != "$GP_VPN_WIFI" && "$gpSsid" != "$GP_HOME_WIFI" ]]; then
    print -u2 -- "用法：wifi-switch $GP_VPN_WIFI 或 wifi-switch $GP_HOME_WIFI"
    return 1
  fi
  gpCur=$(gp-net-current-ssid)
  if [[ "$gpCur" == "$gpSsid" ]]; then
    print -r -- "当前已在 $gpSsid。"
    return 0
  fi
  _gp-progress-run "正在加入 $gpSsid" _gp-wifi-join-default "$gpSsid"
  gpStatus=$?
  if (( gpStatus == 0 )); then
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
  while true; do
    gpPassword=''
    if ! IFS= read -rs "gpPassword?请输入 $gpSsid 的 Wi-Fi 密码（输入时不显示，直接回车取消）："; then
      print -ru2 -- ''
      return 1
    fi
    print -ru2 -- ''
    [[ -n "$gpPassword" ]] || return 1
    gpStatus=0
    print -r -- "$gpPassword" | _gp-progress-run "正在验证 Wi-Fi 密码并加入 $gpSsid" _gp-wifi-join "$gpSsid" - || gpStatus=$?
    (( gpStatus == 0 )) && break
    case "$gpStatus" in
      2) print -ru2 -- "Wi-Fi 密码验证失败，请重新输入。" ;;
      3) print -ru2 -- "连接 $gpSsid 超时或尚未就绪，请核对密码后重新输入。" ;;
      *) print -ru2 -- "未能加入 $gpSsid，请确认网络可用后重新输入密码。" ;;
    esac
  done
  print -r -- "已加入 $gpSsid。"
  if ! print -rn -- "$gpPassword" | "$gpKeychain" save "$gpSsid"; then
    print -u2 -- 'Wi-Fi 已连接，但密码未能保存到本机钥匙串。'
  fi
  return 0
}

_gp-net-wait-wifi() {
  emulate -L zsh
  local gpSsid="$1" gpAttempt gpCur gpReady=0
  for gpAttempt in {1..20}; do
    gpCur=$(gp-net-current-ssid)
    if [[ -n "$gpCur" && "$gpCur" != '<redacted>' && "$gpCur" != "$gpSsid" ]]; then
      gpReady=0
    elif /usr/sbin/ipconfig getifaddr "$GP_WIFI_IFACE" >/dev/null 2>&1 &&
       /usr/sbin/ipconfig getoption "$GP_WIFI_IFACE" router >/dev/null 2>&1; then
      (( ++gpReady >= 2 )) && return 0
    else
      gpReady=0
    fi
    /bin/sleep 1
  done
  print -u2 -- "$gpSsid 的连接尚未确认，或 Wi-Fi 尚未获得 IPv4 地址和路由。"
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
      if [[ -t 2 ]]; then
        printf >&2 '\r\033[2K%s %s… %s 秒' "${gpFrames[$((gpElapsed % ${#gpFrames} + 1))]}" "$gpLabel" "$gpElapsed"
      elif [[ "$gpState" != "$gpLast" ]] || (( gpElapsed - gpLastTick >= 10 )); then
        print -ru2 -- "$gpLabel… $gpElapsed 秒"
        gpLastTick="$gpElapsed"
      fi
      gpLast="$gpState"
      /bin/sleep 1
    done
  } always {
    [[ ! -t 2 ]] || printf >&2 '\r\033[2K'
  }
  if (( gpStatus == 0 )); then
    print -r -- "VPN 已连接，隧道已建立（等待 $((SECONDS - gpStart)) 秒）。"
    return 0
  fi
  print -ru2 -- "等待 ${gpTimeout} 秒后仍未确认 VPN 隧道建立。请在 GlobalProtect 查看连接或登录状态。"
  return 1
}

gp-connect() {
  emulate -L zsh
  print -r -- "连接集团 VPN:先切换到 $GP_VPN_WIFI …"
  if ! wifi-switch "$GP_VPN_WIFI" ||
     ! _gp-progress-run "正在确认 $GP_VPN_WIFI 网络就绪" _gp-net-wait-wifi "$GP_VPN_WIFI"; then
    print -u2 -- '网络未就绪,已取消启动 GlobalProtect。'
    return 1
  fi
  print -r -- '网络已就绪,启动 GlobalProtect …'
  gp-start || return
  _gp-wait-vpn
}
