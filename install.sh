#!/bin/zsh -f
set -eu
umask 022

root=${0:A:h}
source "$root/src/check-globalprotect.sh"
source "$root/src/check-toolchain.zsh"
source "$root/src/terminal-banner.zsh"
target='/Applications/Ashley VPN.app'
domain='com.ashley.vpn.companion'

install_accent=$(ashley_terminal_accent)
install_state="$HOME/Library/Application Support/Ashley VPN"

install_welcome_panel() {
  local primary='安装 Ashley VPN' details='检查安装条件和集团 VPN 证书权限'
  local next_title='启动应用' next_step='在新终端运行 ashleyvpn'
  local columns=0
  if [[ -t 1 && "${TERM:-dumb}" != dumb ]]; then columns=$(ashley_terminal_columns); fi
  case "$mode" in
    --check)
      primary='检查安装条件' details='macOS、GlobalProtect 和 Swift 工具链'
      next_title='检查安装位置' next_step='确认「应用程序」目录可写入'
      ;;
    --repair-keychain|--restore-keychain-prompt)
      primary='修复集团 VPN 证书权限' details='检查系统钥匙串中的 VPN 私钥'
      next_title='管理员验证' next_step='仅在需要修改授权时提示输入密码'
      ;;
  esac

  ashley_welcome_panel "$1" "$2" "$columns" "$primary" "$details" "$next_title" "$next_step"
}

install_section() {
  printf '\n  '
  ashley_banner_paint '2' '──'
  printf ' '
  ashley_banner_paint "$install_accent" "$1"
  printf '\n'
}

install_message() {
  local color icon
  case "$1" in
    done) color='1;32' icon='✓' ;;
    warn) color='1;33' icon='!' ;;
    error) color='1;31' icon='✕' ;;
    *) color="$install_accent" icon='›' ;;
  esac
  printf '  '
  ashley_banner_paint "$color" "$icon"
  printf '  %s\n' "$2"
}

install_wait() {
  local label="$1"
  shift
  if ashley_can_animate 1; then
    ashley_with_spinner 1 "$label" "$@"
  else
    install_message info "$label"
    "$@"
  fi
}

mode="${1:-}"
if (( $# > 1 )) || [[ -n "$mode" && "$mode" != --check && "$mode" != --repair-keychain && "$mode" != --restore-keychain-prompt ]]; then
  print -u2 -- '用法：./install.sh [--check | --repair-keychain | --restore-keychain-prompt]'
  exit 2
fi

fail_check() {
  install_message error "$1 安装已停止。" >&2
  exit 1
}

log_build_output() {
  "$@" > "$stage/build.log" 2>&1
}

report_build_failure() {
  local step="$1" diagnostics
  install_message error "$step。" >&2
  if diagnostics=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/ashley-vpn-build.XXXXXX" 2>/dev/null) &&
     /bin/cp "$stage/build.log" "$diagnostics" 2>/dev/null; then
    install_message info "诊断日志  $diagnostics" >&2
  fi
}

run_build_step() {
  local label="$1" failure="$2"
  shift 2
  if ! install_wait "$label" log_build_output "$@"; then
    report_build_failure "$failure"
    exit 1
  fi
}

compile_certificate_checker() {
  /usr/bin/xcrun swiftc -target "$swift_target" -O \
    "$root/src/globalprotect-keychain.swift" -o "$stage/globalprotect-keychain"
}

capture_certificate_check() {
  local checker="$1" option="$2"
  if [[ ! -x "$checker" ]] && ! log_build_output compile_certificate_checker; then
    certificate_build_failed=true
    return 1
  fi
  "$checker" "$option" > "$stage/certificate-check.out" 2> "$stage/certificate-check.err"
}

show_certificate_help() {
  local globalprotect='/Applications/GlobalProtect.app'
  local pangps="$globalprotect/Contents/Resources/PanGPS"
  local system_keychain='/Library/Keychains/System.keychain'
  # Show the paths users can paste into Finder's file chooser on this Mac.
  globalprotect=${globalprotect:A}
  pangps=${pangps:A}
  print -ru2 -- '可在「钥匙串访问 → 系统 → 集团 VPN 客户端证书 → 私钥 → 访问控制」核对权限。'
  print -ru2 -- '在访问控制里点「+」，按 ⇧⌘G，粘贴缺少的应用路径：'
  print -ru2 -- "$globalprotect"
  print -ru2 -- "$pangps"
  [[ -t 2 && -z "${SSH_CONNECTION:-}" ]] || return 0
  local action
  if action=$(/usr/bin/osascript - "$1" "$system_keychain" "$globalprotect" "$pangps" 2>/dev/null <<'APPLESCRIPT'
on run argv
    set summary to item 1 of argv
    set keychainPath to item 2 of argv
    set globalProtectPath to item 3 of argv
    set panGPSPath to item 4 of argv
    set instructions to "在「系统」钥匙串里展开集团 VPN 客户端证书，打开其私钥的「访问控制」，保留「允许访问之前确认」。" & return & keychainPath & return & return & "点 + 后按 ⇧⌘G，粘贴本机缺少的应用路径（也显示在终端）：" & return & globalProtectPath & return & panGPSPath & return & return & "如果两项都在，但每次仍弹窗，请核对「询问钥匙串密码」。若它是此次升级后才开启的，可恢复原设置。最后点「存储更改」，按 macOS 提示验证。"
    set choice to display dialog (summary & return & return & instructions) with title "Ashley VPN · 集团证书权限" buttons {"稍后处理", "打开钥匙串访问"} default button "打开钥匙串访问" cancel button "稍后处理"
    return button returned of choice
end run
APPLESCRIPT
  ) && [[ "$action" == '打开钥匙串访问' ]]; then
    /usr/bin/open -b com.apple.keychainaccess || true
  fi
}

repair_certificate_access() {
  local checker="$stage/globalprotect-keychain" result check_status=0
  local certificate_build_failed=false
  local check_option=--check write_option=--repair
  local message='检测到权限缺项；验证管理员身份后，将自动补齐集团 VPN 私钥的通用及独立签名授权。'
  if [[ "$mode" == --restore-keychain-prompt ]]; then
    check_option=--check-prompt
    write_option=--restore-prompt
    message='验证管理员身份后，将取消这把集团 VPN 私钥的逐次密码提示，保留现有受信应用。'
  fi
  install_wait '正在检查集团 VPN 证书权限…' capture_certificate_check "$checker" "$check_option" || check_status=$?
  if [[ "$certificate_build_failed" == true ]]; then
    report_build_failure '构建集团 VPN 证书权限组件失败'
    return 1
  fi
  result=$(<"$stage/certificate-check.out")
  if [[ -s "$stage/certificate-check.err" ]]; then
    install_message warn "$(<"$stage/certificate-check.err")" >&2
  fi
  if (( check_status != 3 )); then
    case "$check_status:$result" in
      0:*已齐全*|0:*未开启逐次*) install_message done "$result" ;;
      0:*) install_message info "$result" ;;
      4:*) install_message warn "$result" >&2 ;;
      *) install_message error "$result" >&2 ;;
    esac
    if (( check_status == 4 )); then
      show_certificate_help "$result"
    fi
    return "$check_status"
  fi
  if [[ ! -t 2 ]]; then
    install_message warn '修复私钥权限需要管理员验证，请在 macOS 终端运行。' >&2
    return 1
  fi
  install_message warn "$message"
  local repair_result verify_result
  if ! repair_result=$(/usr/bin/sudo -k -p '  本机管理员密码：' -- "$checker" "$write_option" "$result" </dev/tty); then
    [[ -z "$repair_result" ]] || install_message error "$repair_result" >&2
    show_certificate_help '安装器未能完成或验证自动修复。你可以在钥匙串访问中处理。'
    return 1
  fi
  if ! verify_result=$("$checker" --verify "$result"); then
    install_message error "$verify_result" >&2
    show_certificate_help '当前登录账号未能验证集团 VPN 私钥的授权。你可以在钥匙串访问中检查。'
    return 1
  fi
  install_message done "$repair_result"
  install_message done '已通过当前登录账号复查集团 VPN 私钥权限。'
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
    if [[ "$installed_version" == <->.<->.<-> && "$installed_build" == <-> && -n "$latest_build" ]]; then
      autoload -Uz is-at-least
      if ! is-at-least "$installed_version.$installed_build" "$latest_version.$latest_build"; then
        fail_check "本机 $installed_version（构建 $installed_build）高于安装包 $latest_version（构建 $latest_build），已保留本机版本。"
      fi
    fi
    if [[ "$installed_version" == "$latest_version" && "$installed_build" == "$latest_build" &&
          -x "$target/Contents/MacOS/ashley-vpn-menu" ]]; then
      if [[ -z "${ASHLEY_SIGN_IDENTITY:-}${ASHLEY_HOST_PROFILE:-}${ASHLEY_PROVIDER_PROFILE:-}" ||
            -d "$target/Contents/Library/SystemExtensions/com.ashley.vpn.companion.routing.systemextension" ]]; then
        installed_current=true
      fi
    fi
  fi
}

check_application_directory() {
  if [[ ! -w /Applications ]]; then
    fail_check '「应用程序」目录：当前账号无法写入，请切换到有写入权限的账号后重试。'
  fi
  install_message done '应用程序目录可写入'
}

if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then
  fail_check '操作系统：Ashley VPN 需要 macOS 12 或更新版本。'
fi
swift_target="$(/usr/bin/uname -m)-apple-macos12.0"
release_fields=$(ashley_release_fields "$root/src/Info.plist") || release_fields=''
read -r latest_version latest_build <<< "$release_fields"
if [[ -z "$mode" || "$mode" == --check ]]; then
  check_existing_installation "$mode"
fi
if [[ "${ASHLEY_VPN_ONLINE_INSTALL:-}" == 1 && -n "$release_fields" ]]; then
  version_status='已是最新版'
else
  version_status=$(ashley_release_status "$latest_version" "$latest_build" "$install_state")
fi
install_welcome_panel "$latest_version" "$version_status"
install_section '安装检查'
version=$(/usr/bin/sw_vers -productVersion) || fail_check '操作系统：无法读取 macOS 版本。'
major=${version%%.*}
if [[ "$major" != <-> ]] || (( major < 12 )); then
  fail_check "操作系统：当前为 macOS $version，请升级至 macOS 12 或更新版本。"
fi
install_message done "macOS $version"

install_message info "必需工具链：Swift ≥ $ASHLEY_MIN_SWIFT_VERSION、macOS SDK ≥ $ASHLEY_MIN_MACOS_SDK_VERSION"
toolchain_ready=false
if toolchain_summary=$(ashley_check_active_toolchain); then
  toolchain_ready=true
elif [[ "$mode" != --check ]] && ashley_update_command_line_tools; then
  install_message info '工具更新完成，正在重新检查 Swift 和 macOS SDK 版本…'
  if toolchain_summary=$(ashley_check_active_toolchain); then
    toolchain_ready=true
  fi
fi
if [[ "$toolchain_ready" != true ]]; then
  install_message info '首次安装命令行工具请运行 xcode-select --install。' >&2
  install_message info '请在「系统设置 → 通用 → 软件更新」安装适配当前 macOS 的 Command Line Tools for Xcode 更新。' >&2
  install_message info '如果使用完整 Xcode，请更新 Xcode，并在 Xcode「设置 → 位置 → Command Line Tools」选择新版。' >&2
  install_message info '更新后运行 xcrun swiftc --version 和 xcrun --sdk macosx --show-sdk-version 确认，再重新安装。' >&2
  fail_check 'Xcode 工具链未满足必需版本，尚未开始构建。'
fi
install_message done "$toolchain_summary"

if [[ -z "${1:-}" ]]; then
  [[ -n "$latest_version" ]] || fail_check '无法读取安装包版本。'
fi

if ! check_globalprotect 2>/dev/null; then
  fail_check '集团 GlobalProtect：客户端未安装或不完整，请通过公司渠道安装后重试。'
fi
install_message done '集团 GlobalProtect 已安装'

if [[ "${1:-}" == --check ]]; then
  check_application_directory
  exit 0
fi

state="$install_state"
if [[ -L "$state" || -L "$state/operation.lock" ]]; then
  fail_check 'Ashley VPN 数据位置指向其他路径。'
fi
(umask 077; /bin/mkdir -p "$state"; : >> "$state/operation.lock")
zmodload zsh/system
if ! zsystem flock -t 0 -f install_fd "$state/operation.lock" 2>/dev/null; then
  install_message warn 'Ashley VPN 正在连接或关闭，请等当前操作结束后重试安装。' >&2
  exit 1
fi
if [[ "${ASHLEY_VPN_ONLINE_INSTALL:-}" == 1 && -n "$release_fields" ]]; then
  ashley_record_latest_release "$state" "$release_fields" 2>/dev/null || true
fi
if [[ -z "$mode" ]]; then
  check_existing_installation
  if [[ "$installed_current" == true ]]; then
    if [[ "$version_status" == '已是最新版' ]]; then
      install_message done "Ashley VPN $latest_version 已是最新版"
    else
      install_message done "Ashley VPN $latest_version 已安装"
    fi
  fi
fi
if [[ -n "$mode" || "$installed_current" == true ]]; then
  stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ashley-vpn-keychain.XXXXXX")
  trap '/bin/rm -R -- "$stage"' EXIT
  install_section '证书权限'
  repair_certificate_access
  exit 0
fi
check_application_directory
install_section '应用构建'
if [[ -n "$installed_version" ]]; then
  install_message info "升级 $installed_version → $latest_version"
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
/bin/cp "$root/src/"{connect.command,disconnect.command,toggle.command,run-vpn.zsh,check-globalprotect.sh,gp-processes.sh,globalprotect-control.zsh,setup-stop-authorization.sh,setup-routing-authorization.sh,terminal-banner.zsh} "$resources/"
/bin/cp "$root/src/assets/"{AppIcon.icns,MenuIcon.png,MenuIcon@2x.png,MenuIconDisabled.png,MenuIconDisabled@2x.png,FloatingIcon.png,FloatingIconDisabled.png} "$resources/"
/bin/chmod 755 "$resources/"{connect,disconnect,toggle}.command
if [[ -f "$target/Contents/Resources/installation-id" && ! -L "$target/Contents/Resources/installation-id" ]]; then
  /bin/cp "$target/Contents/Resources/installation-id" "$resources/installation-id"
else
  /usr/bin/uuidgen > "$resources/installation-id"
fi

run_build_step '正在构建 Ashley VPN…' '构建 Ashley VPN 主程序失败' /usr/bin/xcrun swiftc -target "$swift_target" -parse-as-library -O \
  "$root/src/main.swift" "$root/src/FloatingOrb.swift" "$root/src/TerminalSession.swift" \
  "$root/src/WiFiScan.swift" "$root/src/CodexProxyStatus.swift" "$root/src/GlobalProtectConnect.swift" \
  "$root/src/TransparentRouting.swift" "$root/src/DomainRouting.swift" "$root/src/RoutingAuthorization.swift" -o "$app/Contents/MacOS/ashley-vpn-menu"
run_build_step '正在构建网络代理组件…' '构建网络代理组件失败' /usr/bin/xcrun swiftc -target "$swift_target" -parse-as-library -O \
  "$root/src/RoutingService.swift" "$root/src/RoutingIPC.swift" "$root/src/PACServer.swift" "$root/src/DomainRouting.swift" "$root/src/RoutingAuthorization.swift" -o "$resources/routing-service"
/usr/bin/codesign --force --sign - "$resources/routing-service"
run_build_step '正在构建钥匙串组件…'  '构建钥匙串组件失败' /usr/bin/xcrun swiftc -target "$swift_target" -O \
  "$root/src/wifi-keychain.swift" -o "$resources/wifi-keychain"
run_build_step '正在构建证书权限组件…' '构建集团 VPN 证书权限组件失败' compile_certificate_checker
if [[ -n "${ASHLEY_SIGN_IDENTITY:-}${ASHLEY_HOST_PROFILE:-}${ASHLEY_PROVIDER_PROFILE:-}" ]]; then
  run_build_step '正在构建并签名 Codex 网络扩展…' '签名网络扩展失败' /bin/zsh -f "$root/src/sign-routing.zsh" "$app"
else
  if [[ -d "$target/Contents/Library/SystemExtensions" ]]; then
    fail_check '升级已有网络扩展需要签名构建。'
  fi
  install_message info '本地构建使用 macOS 域名代理分流 ChatGPT、Codex 和 OpenAI。'
  run_build_step '正在签名 Ashley VPN…' '签名 Ashley VPN 失败' /usr/bin/codesign --force --deep --sign - "$app"
fi
run_build_step '正在验证应用签名…' '验证 Ashley VPN 签名失败' /usr/bin/codesign --verify --deep --strict "$app"
install_message done '应用构建和签名验证完成'
/bin/zsh -f "$root/src/install-cli.zsh"

# Uninstall the old bundle only after the new one is ready.
if [[ -d "$target" ]]; then
  install_message info '正在替换旧版 Ashley VPN…'
  process='^/Applications/Ashley VPN\.app/Contents/MacOS/ashley-vpn-menu( --open-routed-codex)?$'
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
  install_message error '无法将 Ashley VPN 安装到「应用程序」目录。' >&2
  exit 1
fi

if [[ -d "$stage/previous.app" ]]; then
  for file in operation.owner connected-installation home-wifi-profile; do
    if [[ -f "$state/$file" || -L "$state/$file" ]]; then
      /bin/rm -- "$state/$file" || print -ru2 -- '部分旧安装状态未能删除。'
    fi
  done
fi

previous_keychain="$stage/previous.app/Contents/Resources/wifi-keychain"
if [[ -x "$previous_keychain" ]] && ! /usr/bin/cmp -s \
    "$stage/previous.app/Contents/Resources/installation-id" "$target/Contents/Resources/installation-id"; then
  forget_status=0
  "$previous_keychain" forget-all || forget_status=$?
  if (( forget_status == 2 )); then
    # Older helpers only accepted the two original network names.
    forget_status=0
    "$previous_keychain" forget officewifi && "$previous_keychain" forget OfficeWiFi || forget_status=$?
  fi
  if (( forget_status != 0 )); then
    print -u2 -- '旧安装的钥匙串记录未能删除，新安装仍只会使用自己的记录。'
  fi
fi

install_section '证书权限'
if ! repair_certificate_access; then
  install_message warn '证书权限检查未完成，可在终端重新运行安装命令重试。' >&2
fi
install_section '安装完成'
install_message done "Ashley VPN $latest_version 已安装"
install_message info '在新终端运行 ashleyvpn，打开菜单栏图标。'
