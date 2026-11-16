#!/bin/bash
set -euo pipefail
umask 077

if [ "$(/usr/bin/uname -s)" != Darwin ]; then
    printf '%s\n' 'Ashley VPN 安装脚本仅支持 macOS。' >&2
    exit 1
fi

stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ashley-vpn.XXXXXX")
trap '/bin/rm -R -- "$stage"' EXIT
/usr/bin/curl -q -fsSL --proto '=https' --proto-redir '=https' \
    'https://codeload.github.com/elingembkq222/ashley-vpn/tar.gz/refs/heads/main' \
    -o "$stage/source.tar.gz"
/usr/bin/tar -xzf "$stage/source.tar.gz" --strip-components 1 -C "$stage"
/bin/zsh -f "$stage/install.sh" "$@"
