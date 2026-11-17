#!/bin/bash
set -euo pipefail
umask 077

if [ "$(/usr/bin/uname -s)" != Darwin ]; then
    printf '  ✕  %s\n' 'Ashley VPN 需要 macOS 12 或更新版本。' >&2
    exit 1
fi

stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ashley-vpn.XXXXXX")
trap '/bin/rm -R -- "$stage"' EXIT
printf '\n  › %s\n' '正在下载 Ashley VPN 安装包…'
curl_progress=(-sS)
if [[ -t 2 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
    curl_progress=(--progress-bar -S)
fi
if ! /usr/bin/curl -q -fL "${curl_progress[@]}" --proto '=https' --proto-redir '=https' \
    'https://codeload.github.com/elingembkq222/ashley-vpn/tar.gz/refs/heads/main' \
    -o "$stage/source.tar.gz"; then
    printf '  ✕  %s\n' '下载安装包失败，请确认能访问 GitHub 后重试。' >&2
    exit 1
fi
if ! /usr/bin/tar -xzf "$stage/source.tar.gz" --strip-components 1 -C "$stage"; then
    printf '  ✕  %s\n' '解压安装包失败，请重新运行安装命令。' >&2
    exit 1
fi
/bin/zsh -f "$stage/install.sh" "$@"
