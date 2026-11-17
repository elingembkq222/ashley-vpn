#!/bin/bash
set -euo pipefail
umask 077

if [ "$(/usr/bin/uname -s)" != Darwin ]; then
    printf '  ✕  %s\n' 'Ashley VPN 需要 macOS 12 或更新版本。' >&2
    exit 1
fi

stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ashley-vpn.XXXXXX")
progress_pid=''
download_animated=false
stop_download_progress() {
    if [[ -n "$progress_pid" ]]; then
        kill -TERM "$progress_pid" 2>/dev/null || true
        wait "$progress_pid" 2>/dev/null || true
        progress_pid=''
        printf '\r\033[2K' >&2
    fi
}
trap 'stop_download_progress; /bin/rm -R -- "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

download_size() {
    /usr/bin/awk '
        /^HTTP\// { total = 0; ok = ($2 == 200) }
        ok && tolower($1) == "content-length:" {
            sub(/\r$/, "", $2)
            if ($2 ~ /^[1-9][0-9]*$/ && length($2) < 17) total = $2
        }
        END { printf "%.0f\n", total + 0 }
    ' "$stage/download.headers" 2>/dev/null || printf '0\n'
}

draw_download_progress() {
    local received="$1" total="$2" tick="$3" width=24
    local left=0 filled remaining percent reading prefix bar suffix
    if (( total > 0 )); then
        percent=$((received * 100 / total))
        (( percent <= 100 )) || percent=100
        filled=$((width * percent / 100))
        printf -v reading '%3d%%  %d / %d KiB' "$percent" "$((received / 1024))" "$((total / 1024))"
    else
        filled=4
        left=$((tick % ((width - filled) * 2)))
        (( left <= width - filled )) || left=$(((width - filled) * 2 - left))
        printf -v reading '%d KiB 已下载' "$((received / 1024))"
    fi
    remaining=$((width - left - filled))
    printf -v prefix '%*s' "$left" ''
    printf -v bar '%*s' "$filled" ''
    printf -v suffix '%*s' "$remaining" ''
    printf '\r\033[2K  \033[%sm↓\033[0m  下载  [\033[2m%s\033[0m\033[%sm%s\033[0m\033[2m%s\033[0m]  %s' \
        "$accent" "${prefix// /─}" "$accent" "${bar// /━}" "${suffix// /─}" "$reading" >&2
}

if [[ -t 2 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
    download_animated=true
    case "${COLORTERM:-}:${TERM:-}" in
        truecolor:*|24bit:*) accent='1;38;2;215;119;87' ;;
        *:*256color*) accent='1;38;5;173' ;;
        *) accent='1;33' ;;
    esac
    printf '\n' >&2
    (
        received=0 total=0 tick=0
        trap 'exit 0' TERM
        /bin/sleep 0.12
        while true; do
            received=$(/usr/bin/stat -f '%z' "$stage/source.tar.gz" 2>/dev/null || printf '0')
            (( total > 0 )) || total=$(download_size)
            draw_download_progress "$received" "$total" "$tick"
            tick=$((tick + 1))
            /bin/sleep 0.12
        done
    ) &
    progress_pid=$!
else
    printf '\n  › %s\n' '正在下载 Ashley VPN 安装包…'
fi
if ! /usr/bin/curl -q -fsSL --proto '=https' --proto-redir '=https' \
    'https://codeload.github.com/elingembkq222/ashley-vpn/tar.gz/refs/heads/main' \
    -D "$stage/download.headers" -o "$stage/source.tar.gz" 2>"$stage/download.log"; then
    stop_download_progress
    printf '  ✕  %s\n' '下载安装包失败，请确认能访问 GitHub 后重试。' >&2
    /bin/cat "$stage/download.log" >&2
    exit 1
fi
stop_download_progress
if ! /usr/bin/tar -xzf "$stage/source.tar.gz" --strip-components 1 -C "$stage"; then
    printf '  ✕  %s\n' '解压安装包失败，请重新运行安装命令。' >&2
    exit 1
fi
if [[ "$download_animated" == true ]]; then
    printf '  \033[1;32m✓\033[0m  %s\n' 'Ashley VPN 安装包已下载' >&2
else
    printf '  ✓  %s\n' 'Ashley VPN 安装包已下载'
fi
ASHLEY_VPN_ONLINE_INSTALL=1 /bin/zsh -f "$stage/install.sh" "$@"
