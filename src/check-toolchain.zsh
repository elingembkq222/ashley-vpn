# Minimum build requirements, checked before compiling or changing the installation.
typeset -r ASHLEY_MIN_SWIFT_VERSION=6.2.4
typeset -r ASHLEY_MIN_MACOS_SDK_VERSION=26.2

ashley_check_toolchain_versions() {
  local swift_output="$1" sdk_version="$2" swift_version
  swift_version=$(print -r -- "$swift_output" | /usr/bin/sed -nE \
    's/.*Apple Swift version ([0-9]+(\.[0-9]+)*)[[:space:]].*/\1/p')
  autoload -Uz is-at-least
  if [[ ! "$swift_version" =~ '^[0-9]+(\.[0-9]+)*$' ||
        ! "$sdk_version" =~ '^[0-9]+(\.[0-9]+)*$' ]] ||
     ! is-at-least "$ASHLEY_MIN_SWIFT_VERSION" "$swift_version" ||
     ! is-at-least "$ASHLEY_MIN_MACOS_SDK_VERSION" "$sdk_version"; then
    print -ru2 -- "必需 Swift ≥ $ASHLEY_MIN_SWIFT_VERSION、macOS SDK ≥ $ASHLEY_MIN_MACOS_SDK_VERSION；当前 Swift ${swift_version:-无法识别}、macOS SDK ${sdk_version:-无法识别}。"
    return 1
  fi
  print -r -- "Swift $swift_version / macOS SDK $sdk_version（满足必需版本）"
}

ashley_check_active_toolchain() {
  local swift_output sdk_version
  swift_output=$(/usr/bin/xcrun swiftc --version 2>/dev/null) || swift_output=''
  sdk_version=$(/usr/bin/xcrun --sdk macosx --show-sdk-version 2>/dev/null) || sdk_version=''
  ashley_check_toolchain_versions "$swift_output" "$sdk_version"
}

# Accept only stable Command Line Tools labels, never OS updates or beta packages.
ashley_latest_clt_update() {
  local line label candidate_version latest_label='' latest_version='0'
  autoload -Uz is-at-least
  while IFS= read -r line; do
    [[ "$line" =~ '^[[:space:]]*\*[[:space:]]*(Label:[[:space:]]*)?(Command Line Tools for Xcode.*)$' ]] || continue
    label="$match[2]"
    [[ "$label" =~ '^Command Line Tools for Xcode( [0-9]+(\.[0-9]+)*)?-[0-9]+(\.[0-9]+)*$' ]] || continue
    candidate_version="${label##*-}"
    is-at-least "$ASHLEY_MIN_MACOS_SDK_VERSION" "$candidate_version" || continue
    if is-at-least "$latest_version" "$candidate_version"; then
      latest_label="$label"
      latest_version="$candidate_version"
    fi
  done
  [[ -n "$latest_label" ]] || return 1
  print -r -- "$latest_label"
}

ashley_update_command_line_tools() (
  local developer_dir updates label answer
  developer_dir=$(/usr/bin/xcode-select -p 2>/dev/null) || developer_dir=''
  if [[ "$developer_dir" != /Library/Developer/CommandLineTools ||
        -n "${DEVELOPER_DIR:-}" || -n "${TOOLCHAINS:-}" ]]; then
    install_message warn '当前未使用默认 Command Line Tools，无法自动更新当前工具链。'
    return 1
  fi
  if [[ ! -t 1 ]] || ! { exec 3<>/dev/tty; } 2>/dev/null; then
    install_message warn '自动更新需要交互终端，请在终端中重新运行安装命令。'
    return 1
  fi
  install_message info '正在查询 Apple 提供的 Command Line Tools 更新，可能需要几分钟…'
  if ! updates=$(LC_ALL=C /usr/sbin/softwareupdate --list 2>&1); then
    install_message warn '无法查询 Apple 更新，请检查网络或使用「软件更新」手动安装。'
    return 1
  fi
  if ! label=$(print -r -- "$updates" | ashley_latest_clt_update); then
    install_message warn 'Apple 未提供满足要求的正式版 Command Line Tools 更新，请手动更新工具链或 macOS。'
    return 1
  fi
  install_message info "可安装：$label"
  install_message info '确认后将由系统请求管理员授权，仅安装上述工具更新；管理员密码不由 Ashley VPN 读取或保存。'
  print -nu3 -- '是否现在更新 Command Line Tools？[y/N] '
  read -r answer <&3 || return 1
  case "$answer" in
    y|Y|yes|YES|是) ;;
    *) install_message warn '未授权更新，安装已取消。'; return 1 ;;
  esac
  if ! /usr/bin/sudo -- /usr/sbin/softwareupdate --install "$label" <&3; then
    install_message warn 'Command Line Tools 更新未完成，安装已停止。'
    return 1
  fi
  /usr/bin/xcrun --kill-cache 2>/dev/null || true
)
