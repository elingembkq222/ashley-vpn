#!/bin/zsh -f
set -eu
umask 022

root=${0:A:h}
source "$root/src/check-globalprotect.sh"
target='/Applications/Ashley VPN.app'
domain='com.ashley.vpn.companion'

if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != --check && "$1" != --repair-keychain ]]; }; then
  print -u2 -- '用法：./install.sh [--check | --repair-keychain]'
  exit 2
fi

fail_check() {
  print -ru2 -- "[失败] $1"
  print -ru2 -- '安装已停止。'
  exit 1
}

run_build_step() {
  local step="$1" diagnostics
  shift
  if "$@" > "$stage/build.log" 2>&1; then
    return 0
  fi
  print -ru2 -- "[失败] $step。"
  if diagnostics=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/ashley-vpn-build.XXXXXX" 2>/dev/null) &&
     /bin/cp "$stage/build.log" "$diagnostics" 2>/dev/null; then
    print -ru2 -- "诊断日志：$diagnostics"
  fi
  exit 1
}

build_certificate_checker() {
  MACOSX_DEPLOYMENT_TARGET=12.0 run_build_step '构建集团 VPN 证书权限组件失败' /usr/bin/xcrun swiftc -O \
    "$root/src/globalprotect-keychain.swift" -o "$stage/globalprotect-keychain"
}

repair_certificate_access() {
  local checker="$stage/globalprotect-keychain" result check_status=0
  print -r -- '正在检查集团 VPN 证书权限…'
  result=$("$checker" --check) || check_status=$?
  if (( check_status != 3 )); then
    print -r -- "$result"
    return "$check_status"
  fi
  if [[ ! -t 2 ]]; then
    print -ru2 -- '集团 VPN 证书缺少签名权限，请在 macOS 终端重新运行安装命令。'
    return 1
  fi
  print -r -- '集团 VPN 证书缺少签名权限。验证管理员身份后，将补齐 GlobalProtect 和 PanGPS 的签名权限。'
  /usr/bin/sudo -k -p '请输入本机管理员密码以修复集团 VPN 证书权限：' -- "$checker" --repair "$result" </dev/tty
}

check_existing_installation() {
  installed_version=''
  installed_current=false
  if [[ -L "$target" ]] || { [[ -e "$target" ]] &&
     [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$target/Contents/Info.plist" 2>/dev/null)" != "$domain" ]]; }; then
    fail_check '「应用程序」目录：安装位置已被同名项目占用，请确认并移走该项目后重试。'
  fi
  if [[ -d "$target" && "${1:-}" != --check ]]; then
    local installed_build
    installed_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$target/Contents/Info.plist" 2>/dev/null) ||
      installed_version='未知版本'
    installed_build=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$target/Contents/Info.plist" 2>/dev/null) ||
      installed_build=''
    if [[ "$installed_version" == "$latest_version" && "$installed_build" == "$latest_build" &&
          -x "$target/Contents/MacOS/ashley-vpn-menu" ]]; then
      installed_current=true
    fi
  fi
}

check_application_directory() {
  if [[ ! -w /Applications ]]; then
    fail_check '「应用程序」目录：当前账号无法写入，请切换到有写入权限的账号后重试。'
  fi
  print -r -- '[通过] 「应用程序」目录：可写入，安装位置可用'
  print -r -- '全部安装条件已通过。'
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

if [[ -z "${1:-}" ]]; then
  latest_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$root/src/Info.plist") ||
    fail_check '无法读取安装包版本。'
  latest_build=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$root/src/Info.plist") ||
    fail_check '无法读取安装包构建号。'
fi
if [[ "${1:-}" != --repair-keychain ]]; then
  check_existing_installation "${1:-}"
fi

if ! check_globalprotect 2>/dev/null; then
  fail_check '集团 GlobalProtect：客户端未安装或不完整，请通过公司渠道安装后重试。'
fi
print -r -- '[通过] 集团 GlobalProtect：已安装'

if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1 ||
   ! /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  fail_check 'Xcode 命令行工具：找不到 Swift 编译器或 macOS SDK，请运行 xcode-select --install 后重试。'
fi
print -r -- '[通过] Xcode 命令行工具：Swift 编译器和 macOS SDK 可用'

if [[ "${1:-}" == --check ]]; then
  check_application_directory
  exit 0
fi

state="$HOME/Library/Application Support/Ashley VPN"
if [[ -L "$state" || -L "$state/operation.lock" ]]; then
  fail_check 'Ashley VPN 数据位置指向其他路径。'
fi
(umask 077; /bin/mkdir -p "$state"; : >> "$state/operation.lock")
zmodload zsh/system
if ! zsystem flock -t 0 -f install_fd "$state/operation.lock" 2>/dev/null; then
  print -u2 -- 'Ashley VPN 正在连接或关闭，请等终端操作结束后重试安装。'
  exit 1
fi
if [[ "${1:-}" != --repair-keychain ]]; then
  check_existing_installation
  if [[ "$installed_current" == true ]]; then
    print -r -- "Ashley VPN $latest_version 已是最新版，无需重装。"
  fi
fi
if [[ "${1:-}" == --repair-keychain || "$installed_current" == true ]]; then
  stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ashley-vpn-keychain.XXXXXX")
  trap '/bin/rm -R -- "$stage"' EXIT
  build_certificate_checker
  repair_certificate_access
  exit 0
fi
check_application_directory
if [[ -n "$installed_version" ]]; then
  print -r -- "检测到 Ashley VPN $installed_version，将准备 $latest_version 并移除旧安装。"
fi

stage=$(/usr/bin/mktemp -d /Applications/.ashley-vpn.install.XXXXXX)
cleanup_install() {
  if [[ -d "$stage/previous.app" && ! -e "$target" && ! -L "$target" ]]; then
    if /bin/mv "$stage/previous.app" "$target"; then
      print -ru2 -- '已恢复此前的 Ashley VPN。'
    else
      print -ru2 -- "无法恢复此前的 Ashley VPN，旧应用保留在 $stage/previous.app。"
      return
    fi
  fi
  /bin/rm -R -- "$stage"
}
trap cleanup_install EXIT
app="$stage/Ashley VPN.app"
resources="$app/Contents/Resources"
/bin/mkdir -p "$resources" "$app/Contents/MacOS"
/bin/cp "$root/src/Info.plist" "$app/Contents/Info.plist"
/bin/cp "$root/src/"{connect.command,disconnect.command,toggle.command,run-vpn.zsh,check-globalprotect.sh,globalprotect-control.zsh,setup-stop-authorization.sh} "$resources/"
/bin/cp "$root/src/assets/"{AppIcon.icns,MenuIcon.png,MenuIcon@2x.png,MenuIconDisabled.png,MenuIconDisabled@2x.png,FloatingIcon.png,FloatingIconDisabled.png} "$resources/"
/bin/chmod 755 "$resources/"{connect,disconnect,toggle}.command
/usr/bin/uuidgen > "$resources/installation-id"

print -r -- '正在构建 Ashley VPN…'
MACOSX_DEPLOYMENT_TARGET=12.0 run_build_step '构建 Ashley VPN 主程序失败' /usr/bin/xcrun swiftc -parse-as-library -O \
  "$root/src/main.swift" "$root/src/FloatingOrb.swift" "$root/src/TerminalSession.swift" -o "$app/Contents/MacOS/ashley-vpn-menu"
MACOSX_DEPLOYMENT_TARGET=12.0 run_build_step '构建钥匙串组件失败' /usr/bin/xcrun swiftc -O \
  "$root/src/wifi-keychain.swift" -o "$resources/wifi-keychain"
build_certificate_checker
run_build_step '签名 Ashley VPN 失败' /usr/bin/codesign --force --deep --sign - "$app"
run_build_step '验证 Ashley VPN 签名失败' /usr/bin/codesign --verify --deep --strict "$app"
/bin/zsh -f "$root/src/install-cli.zsh"

# Uninstall the old bundle only after the new one is ready.
if [[ -d "$target" ]]; then
  print -r -- '正在移除旧版 Ashley VPN…'
  process='^/Applications/Ashley VPN\.app/Contents/MacOS/ashley-vpn-menu$'
  /usr/bin/pkill -TERM -u "$EUID" -f "$process" || true
  for attempt in {1..20}; do
    /usr/bin/pgrep -u "$EUID" -f "$process" >/dev/null || break
    /bin/sleep 0.1
  done
  if /usr/bin/pgrep -u "$EUID" -f "$process" >/dev/null; then
    fail_check '旧版 Ashley VPN 尚未退出，请退出后重试。'
  fi
  /bin/mv "$target" "$stage/previous.app"
fi
if ! /bin/mv "$app" "$target"; then
  print -ru2 -- '[失败] 无法将 Ashley VPN 安装到「应用程序」目录。'
  exit 1
fi

if [[ -d "$stage/previous.app" ]]; then
  for file in operation.owner connected-installation home-wifi-profile; do
    if [[ -f "$state/$file" || -L "$state/$file" ]]; then
      /bin/rm -- "$state/$file" || print -ru2 -- '部分旧安装状态未能删除。'
    fi
  done
  if /usr/bin/defaults read "$domain" >/dev/null 2>&1 &&
     ! /usr/bin/defaults delete "$domain"; then
    print -ru2 -- '旧版本应用设置未能删除。'
  fi
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

if ! repair_certificate_access; then
  print -ru2 -- 'Ashley VPN 已安装，集团 VPN 证书权限未修复。可在终端重新运行安装命令重试。'
fi
print -r -- "Ashley VPN 已安装（$latest_version）。打开新的终端窗口，运行 ashleyvpn 启动菜单栏图标。"
