#!/bin/zsh -f
set -eu
umask 077

uninstall_ashley_vpn() {
  local app='/Applications/Ashley VPN.app'
  local domain='com.ashley.vpn.companion'
  local state="$HOME/Library/Application Support/Ashley VPN"
  local launcher="$HOME/.local/bin/ashleyvpn"
  local process='^/Applications/Ashley VPN\.app/Contents/MacOS/ashley-vpn-menu$'
  local uninstall_fd trash ssid file attempt

  if [[ "$(/usr/bin/uname -s)" != Darwin ]] || (( EUID == 0 )); then
    print -ru2 -- '请在安装 Ashley VPN 的 Mac 账户下运行卸载命令。'
    return 1
  fi
  if [[ -L "$app" ]] || { [[ -e "$app" ]] &&
      [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null)" != "$domain" ]]; }; then
    print -ru2 -- '安装位置有同名项目，无法确认它是 Ashley VPN，卸载已停止。'
    return 1
  fi
  if [[ -L "$state" || -L "$state/operation.lock" ]]; then
    print -ru2 -- 'Ashley VPN 数据位置指向其他路径，卸载已停止。'
    return 1
  fi
  /bin/mkdir -p "$state"
  : >> "$state/operation.lock"
  zmodload zsh/system
  if ! zsystem flock -t 2 -f uninstall_fd "$state/operation.lock" 2>/dev/null; then
    print -ru2 -- 'Ashley VPN 正在操作，请等待操作结束后再卸载。'
    return 1
  fi

  /usr/bin/pkill -TERM -u "$EUID" -f "$process" || true
  for attempt in {1..20}; do
    /usr/bin/pgrep -u "$EUID" -f "$process" >/dev/null || break
    /bin/sleep 0.1
  done
  if /usr/bin/pgrep -u "$EUID" -f "$process" >/dev/null; then
    print -ru2 -- 'Ashley VPN 尚未退出，请退出后重试。'
    return 1
  fi

  if [[ -d "$app" ]]; then
    if [[ -x "$app/Contents/Resources/wifi-keychain" ]]; then
      for ssid in officewifi OfficeWiFi; do
        if ! "$app/Contents/Resources/wifi-keychain" forget "$ssid"; then
          print -ru2 -- "无法删除 Ashley VPN 保存的 $ssid 凭据，请解锁钥匙串后重试。"
          return 1
        fi
      done
    else
      print -ru2 -- '安装缺少钥匙串组件，无法清理 Ashley VPN 保存的 Wi-Fi 凭据。'
    fi
    /bin/mkdir -p "$HOME/.Trash"
    trash="$HOME/.Trash/Ashley VPN $(/usr/bin/uuidgen).app"
    /bin/mv "$app" "$trash"
  fi
  if [[ -f "$launcher" && ! -L "$launcher" ]] &&
     /usr/bin/grep -qxF '# Ashley VPN launcher' "$launcher"; then
    /bin/rm -- "$launcher"
  fi
  if /usr/bin/defaults read "$domain" >/dev/null 2>&1; then
    /usr/bin/defaults delete "$domain"
  fi
  for file in operation.lock operation.owner connected-installation home-wifi-profile; do
    if [[ -f "$state/$file" || -L "$state/$file" ]]; then
      /bin/rm -- "$state/$file"
    fi
  done
  if ! /bin/rmdir "$state" 2>/dev/null; then
    print -r -- '数据目录中有其他文件，已保留。'
  fi
  print -r -- 'Ashley VPN 已卸载。'
}

uninstall_ashley_vpn
