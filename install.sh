#!/bin/zsh -f
set -eu
umask 022

root=${0:A:h}
source "$root/src/check-globalprotect.sh"

if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != --check ]]; }; then
  print -u2 -- '用法：./install.sh [--check]'
  exit 2
fi

fail_check() {
  print -ru2 -- "[失败] $1"
  print -ru2 -- '安装已停止。'
  exit 1
}

print -r -- '正在检查 Ashley VPN 安装条件…'
if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then
  fail_check '操作系统：Ashley VPN 需要 macOS 12 或更新版本。'
fi
version=$(/usr/bin/sw_vers -productVersion) || fail_check '操作系统：无法读取 macOS 版本。'
major=${version%%.*}
if [[ "$major" != <-> ]] || (( major < 12 )); then
  fail_check "操作系统：当前为 macOS $version，请升级至 macOS 12 或更新版本。"
fi
print -r -- "[通过] 操作系统：macOS $version"

if ! check_globalprotect 2>/dev/null; then
  fail_check '集团 GlobalProtect：客户端未安装或不完整，请通过公司渠道安装后重试。'
fi
print -r -- '[通过] 集团 GlobalProtect：已安装'

if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1 ||
   ! /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  fail_check 'Xcode 命令行工具：找不到 Swift 编译器或 macOS SDK，请运行 xcode-select --install 后重试。'
fi
print -r -- '[通过] Xcode 命令行工具：Swift 编译器和 macOS SDK 可用'

target='/Applications/Ashley VPN.app'
if [[ ! -w /Applications ]]; then
  fail_check '「应用程序」目录：当前账号无法写入，请切换到有写入权限的账号后重试。'
fi
if [[ -L "$target" ]] || { [[ -e "$target" ]] &&
   [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$target/Contents/Info.plist" 2>/dev/null)" != com.ashley.vpn.companion ]]; }; then
  fail_check '「应用程序」目录：安装位置已被同名项目占用，请确认并移走该项目后重试。'
fi
print -r -- '[通过] 「应用程序」目录：可写入，安装位置可用'
print -r -- '全部安装条件已通过。'
if [[ "${1:-}" == --check ]]; then
  exit 0
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
/bin/cp "$root/src/"{connect.command,disconnect.command,toggle.command,run-vpn.zsh,check-globalprotect.sh,globalprotect-control.zsh,setup-stop-authorization.sh} "$resources/"
/bin/cp "$root/src/assets/"{AppIcon.icns,MenuIcon.png,MenuIcon@2x.png,MenuIconDisabled.png,MenuIconDisabled@2x.png,FloatingIcon.png,FloatingIconDisabled.png} "$resources/"
/bin/chmod 755 "$resources/"{connect,disconnect,toggle}.command
/usr/bin/uuidgen > "$resources/installation-id"

print -r -- '正在构建 Ashley VPN…'
MACOSX_DEPLOYMENT_TARGET=12.0 /usr/bin/xcrun swiftc -parse-as-library -O \
  "$root/src/main.swift" "$root/src/FloatingOrb.swift" "$root/src/TerminalSession.swift" -o "$app/Contents/MacOS/ashley-vpn-menu"
MACOSX_DEPLOYMENT_TARGET=12.0 /usr/bin/xcrun swiftc -O "$root/src/wifi-keychain.swift" -o "$resources/wifi-keychain"
/usr/bin/codesign --force --deep --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
/bin/zsh -f "$root/src/install-cli.zsh"

# Replace only the menu app. An ongoing VPN tunnel stays with GlobalProtect.
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

print -r -- 'Ashley VPN 已安装。打开新的终端窗口，运行 ashleyvpn 启动菜单栏图标。'
