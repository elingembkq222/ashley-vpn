#!/bin/zsh -f
set -eu
umask 022

root=${0:A:h}
source "$root/src/check-globalprotect.sh"

if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then
  print -u2 -- 'Ashley VPN 安装脚本仅支持 macOS。'
  exit 1
fi
if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != --check ]]; }; then
  print -u2 -- '用法：./install.sh [--check]'
  exit 2
fi

check_globalprotect || exit 1
if [[ "${1:-}" == --check ]]; then
  print -r -- '已检测到集团 GlobalProtect 客户端。'
  exit 0
fi
if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 -- '请先运行 xcode-select --install 安装 Xcode Command Line Tools，再重试。'
  exit 1
fi

target='/Applications/Ashley VPN.app'
if [[ ! -w /Applications ]]; then
  print -u2 -- '当前账号无法写入「应用程序」目录，请由这台 Mac 的管理员账号运行安装脚本。'
  exit 1
fi
if [[ -L "$target" ]] || { [[ -e "$target" ]] &&
   [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$target/Contents/Info.plist" 2>/dev/null)" != com.ashley.vpn.companion ]]; }; then
  print -u2 -- '「应用程序」中已有同名但不同的应用，安装已停止。'
  exit 1
fi

state="$HOME/Library/Application Support/Ashley VPN"
(umask 077; /bin/mkdir -p "$state"; : >> "$state/operation.lock")
zmodload zsh/system
if ! zsystem flock -t 0 -f install_fd "$state/operation.lock"; then
  print -u2 -- 'Ashley VPN 正在连接或关闭，请等终端操作结束后重试安装。'
  exit 1
fi

stage=$(/usr/bin/mktemp -d /Applications/.ashley-vpn.install.XXXXXX)
trap 'if [[ ! -e "$stage/previous.app" || -e "$target" ]]; then /bin/rm -R -- "$stage"; fi' EXIT
app="$stage/Ashley VPN.app"
resources="$app/Contents/Resources"
/bin/mkdir -p "$resources" "$app/Contents/MacOS"
/bin/cp "$root/src/Info.plist" "$app/Contents/Info.plist"
/bin/cp "$root/src/"{connect.command,disconnect.command,run-vpn.zsh,check-globalprotect.sh,globalprotect-control.zsh,setup-stop-authorization.sh} "$resources/"
/bin/chmod 755 "$resources/connect.command" "$resources/disconnect.command"
/usr/bin/uuidgen > "$resources/installation-id"

print -r -- '正在构建 Ashley VPN…'
MACOSX_DEPLOYMENT_TARGET=12.0 /usr/bin/xcrun swiftc -parse-as-library -O "$root/src/main.swift" -o "$app/Contents/MacOS/ashley-vpn-menu"
MACOSX_DEPLOYMENT_TARGET=12.0 /usr/bin/xcrun swiftc -O "$root/src/wifi-keychain.swift" -o "$resources/wifi-keychain"
/usr/bin/codesign --force --deep --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"

# Restart only the menu icon. An ongoing VPN tunnel stays with GlobalProtect.
if [[ -d "$target" ]]; then
  /usr/bin/pkill -u "$(/usr/bin/id -u)" -x ashley-vpn-menu || true
  /bin/mv "$target" "$stage/previous.app"
fi
if ! /bin/mv "$app" "$target"; then
  [[ ! -d "$stage/previous.app" ]] || /bin/mv "$stage/previous.app" "$target"
  print -u2 -- '安装失败，已尝试恢复此前的应用。'
  exit 1
fi

previous_keychain="$stage/previous.app/Contents/Resources/wifi-keychain"
if [[ -x "$previous_keychain" ]]; then
  for ssid in officewifi OfficeWiFi; do
    if ! "$previous_keychain" forget "$ssid"; then
      print -u2 -- '旧安装的钥匙串记录未能删除，新安装仍只会使用自己的记录。'
      break
    fi
  done
fi

/usr/bin/open -g "$target"
print -r -- '已安装并启动 Ashley VPN。请在 macOS 菜单栏点击盾牌图标。'
