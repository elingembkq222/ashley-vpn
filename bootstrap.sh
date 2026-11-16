#!/bin/bash
set -euo pipefail
umask 077

if [ "$(/usr/bin/uname -s)" != Darwin ]; then
    printf '%s\n' '[失败] 操作系统：Ashley VPN 需要 macOS 12 或更新版本。安装已停止。' >&2
    exit 1
fi

stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ashley-vpn.XXXXXX")
trap '/bin/rm -R -- "$stage"' EXIT
printf '%s\n' '正在下载 Ashley VPN 安装包…'
if ! /usr/bin/curl -q -fsSL --proto '=https' --proto-redir '=https' \
    'https://codeload.github.com/elingembkq222/ashley-vpn/tar.gz/refs/heads/main' \
    -o "$stage/source.tar.gz"; then
    printf '%s\n' '[失败] 下载安装包：请确认能访问 GitHub 后重试。安装已停止。' >&2
    exit 1
fi
if ! /usr/bin/tar -xzf "$stage/source.tar.gz" --strip-components 1 -C "$stage"; then
    printf '%s\n' '[失败] 解压安装包：请重新运行安装命令。安装已停止。' >&2
    exit 1
fi
/bin/zsh -f "$stage/install.sh" "$@"
