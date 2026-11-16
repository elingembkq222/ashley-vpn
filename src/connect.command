#!/bin/zsh -f
exec /bin/zsh -f "${0:A:h}/run-vpn.zsh" connect
