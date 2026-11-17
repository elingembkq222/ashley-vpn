# Shared Ashley VPN heading and release status for the installer and input screens.
ashley_terminal_accent() {
  case "${COLORTERM:-}:${TERM:-}" in
    truecolor:*|24bit:*) print -r -- '1;38;2;215;119;87' ;;
    *:*256color*) print -r -- '1;38;5;173' ;;
    *) print -r -- '1;33' ;;
  esac
}

ashley_banner_paint() {
  if [[ ( -t 1 || "${ASHLEY_VPN_BUFFERED_TTY:-}" == 1 ) && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
    printf '\033[%sm%s\033[0m' "$1" "$2"
  else
    printf '%s' "$2"
  fi
}

ashley_can_animate() {
  [[ -t "$1" && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]
}

ashley_fit_terminal_text() {
  local label="$1" width="$2"
  (( width > 0 )) || return 0
  if (( ${(m)#label} > width )); then
    while (( ${(m)#label} >= width )); do label=${label[1,-2]}; done
    label+='…'
  fi
  printf '%s' "$label"
}

ashley_stop_spinner() {
  [[ -n "$ashley_spinner_pid" ]] || return 0
  kill -TERM "$ashley_spinner_pid" 2>/dev/null || true
  wait "$ashley_spinner_pid" 2>/dev/null || true
  ashley_spinner_pid=''
  printf '\r\033[2K' >&$ashley_spinner_fd
}

ashley_with_spinner() {
  local ashley_spinner_fd="$1" label="$2" ashley_spinner_pid='' code=0 accent columns
  shift 2
  accent=$(ashley_terminal_accent)
  columns=$(ashley_terminal_columns)
  # Keep the animation on one line, including its five-column marker prefix.
  if (( columns > 0 )); then
    label=$(ashley_fit_terminal_text "$label" "$((columns - 6))")
  fi
  setopt localoptions localtraps
  trap 'ashley_stop_spinner; exit 130' INT
  trap 'ashley_stop_spinner; exit 143' TERM
  (
    local frame
    trap 'exit 0' TERM
    /bin/sleep 0.12
    while true; do
      for frame in ◐ ◓ ◑ ◒; do
        printf '\r\033[2K\033[%sm%s\033[0m%s' "$accent" "${label:+  }$frame" "${label:+  }$label" >&$ashley_spinner_fd
        /bin/sleep 0.12
      done
    done
  ) &
  ashley_spinner_pid=$!
  {
    "$@" || code=$?
  } always {
    ashley_stop_spinner
  }
  return "$code"
}

ashley_banner_cell() {
  local label="$1" width="$2" style="$3"
  if (( ${(m)#label} > width )); then
    label=$(ashley_fit_terminal_text "$label" "$width")
  fi
  ashley_banner_paint "$style" "$label"
  printf '%*s' "$((width - ${(m)#label}))" ''
}

ashley_terminal_columns() {
  local rows columns dimensions=''
  if [[ -t 0 ]]; then dimensions=$(/bin/stty size 2>/dev/null) || dimensions=''; fi
  read -r rows columns <<< "$dimensions"
  if [[ "$columns" != <1-> ]]; then
    dimensions=$(/bin/stty -f /dev/tty size 2>/dev/null) || dimensions=''
    read -r rows columns <<< "$dimensions"
  fi
  [[ "$columns" == <1-> ]] && print -r -- "$columns" || print 0
}

ashley_panel_width() {
  local columns="$1"
  # The installer and Wi-Fi picker share this outer width, excluding indentation.
  print -r -- "$((columns < 36 ? 0 : columns > 80 ? 76 : columns - 4))"
}

ashley_welcome_panel() {
  local release="$1" availability="$2" columns="$3" title='Ashley VPN' accent width
  local primary="${4:-}" details="${5:-}" next_title="${6:-}" next_step="${7:-}"
  accent=$(ashley_terminal_accent)
  width=$(ashley_panel_width "$columns")
  title+=" ${release:+v}${release:-版本未知}"
  printf '\n'
  if (( width == 0 )); then
    ashley_banner_paint "$accent" "  ✻ $title"
    printf '\n  %s\n' "$availability"
    return
  fi

  local rule='' top="╭── $title " left_width=20 right_width index
  local top_rule=$((width - ${(m)#top} - 1)) bottom_rule=$((width - 2))
  local -a art=('        ▄  ▄' '      ▄ █  █ ▄' '      █  ▄▄  █' '        ████' '        ▀▀▀▀')
  local -a content=("  版本状态  $availability" "  $primary" "  $details" "  $next_title" "  $next_step")
  local -a styles=("$accent" "$accent" '0' "$accent" '0')
  if (( width >= 64 )); then
    right_width=$((width - left_width - 3))
  else
    right_width=$bottom_rule
  fi

  ashley_banner_paint "$accent" "  $top${(l:$top_rule::─:)rule}╮"
  printf '\n'
  for (( index = 1; index <= ${#content}; index++ )); do
    ashley_banner_paint "$accent" '  │'
    if (( width >= 64 )); then
      ashley_banner_cell "$art[index]" "$left_width" "$accent"
      ashley_banner_paint "$accent" '│'
    fi
    ashley_banner_cell "$content[index]" "$right_width" "$styles[index]"
    ashley_banner_paint "$accent" '│'
    printf '\n'
  done
  ashley_banner_paint "$accent" "  ╰${(l:$bottom_rule::─:)rule}╯"
  printf '\n'
}

ashley_release_fields() {
  local version build
  version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$1" 2>/dev/null) || return 1
  build=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$1" 2>/dev/null) || return 1
  [[ "$version" == <->.<->.<-> && "$build" == <-> ]] || return 1
  print -r -- "$version $build"
}

ashley_record_latest_release() {
  local state="$1" entry="$2" scratch
  scratch=$(/usr/bin/mktemp "$state/.latest-release.XXXXXX") || return 1
  if ! printf '%s %s\n' "$(/bin/date +%s)" "$entry" > "$scratch" ||
     ! /bin/mv -f -- "$scratch" "$state/latest-release"; then
    /bin/rm -f -- "$scratch"
    return 1
  fi
}

ashley_fresh_release() {
  local stamp version build now
  { read -r stamp version build < "$1/latest-release"; } 2>/dev/null || return 1
  [[ "$stamp" == <-> && "$version" == <->.<->.<-> && "$build" == <-> ]] || return 1
  now=$(/bin/date +%s)
  (( now >= stamp && now - stamp <= 300 )) || return 1
  print -r -- "$version $build"
}

ashley_release_status() {
  local current="$1" build="$2" remote version remote_build
  if [[ "$current" != <->.<->.<-> || "$build" != <-> ]] || ! remote=$(ashley_fresh_release "$3"); then
    print -r -- '更新状态待确认'
    return
  fi
  read -r version remote_build <<< "$remote"
  if [[ "$current" == "$version" && "$build" == "$remote_build" ]]; then
    print -r -- '已是最新版'
  else
    autoload -Uz is-at-least
    if is-at-least "$current.$build" "$version.$remote_build"; then
      print -r -- "有新版 v$version"
    else
      print -r -- '当前版本高于线上版'
    fi
  fi
}

ashley_refresh_latest_release() {
  local state="$1" scratch entry
  ashley_fresh_release "$state" >/dev/null && return 0
  scratch=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/ashley-release.XXXXXX") || return 1
  {
    if /usr/bin/curl -q -fsSL --proto '=https' --proto-redir '=https' --max-time 3 \
        'https://raw.githubusercontent.com/elingembkq222/ashley-vpn/main/src/Info.plist' -o "$scratch" &&
       entry=$(ashley_release_fields "$scratch"); then
      ashley_record_latest_release "$state" "$entry"
    fi
  } always {
    /bin/rm -f -- "$scratch"
  }
}
