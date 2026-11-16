#!/bin/zsh -f
set -eu

bin="$HOME/.local/bin"
launcher="$bin/ashleyvpn"
source_file="${0:A:h}/ashleyvpn"
if [[ -L "$launcher" ]] || { [[ -e "$launcher" ]] &&
    { [[ ! -f "$launcher" ]] || ! /usr/bin/grep -qxF '# Ashley VPN launcher' "$launcher"; }; }; then
    print -u2 -- "已有其他程序占用 $launcher，安装已停止。"
    exit 1
fi

case "${SHELL:-/bin/zsh}" in
  */zsh) profile="${ZDOTDIR:-$HOME}/.zshrc" ;;
  */bash)
    profile="$HOME/.bash_profile"
    if [[ ! -e "$profile" ]]; then
      if [[ -f "$HOME/.bash_login" ]]; then
        profile="$HOME/.bash_login"
      elif [[ -f "$HOME/.profile" ]]; then
        profile="$HOME/.profile"
      fi
    fi
    ;;
  *) profile='' ;;
esac

/bin/mkdir -p "$bin"
stage=$(/usr/bin/mktemp "$bin/.ashleyvpn.XXXXXX")
trap 'if [[ -f "$stage" ]]; then /bin/rm -- "$stage"; fi' EXIT
/usr/bin/install -m 755 "$source_file" "$stage"
/bin/mv -f "$stage" "$launcher"

if [[ -n "$profile" ]]; then
  if [[ ! -f "$profile" ]] || ! /usr/bin/grep -qxF '# >>> Ashley VPN PATH >>>' "$profile"; then
    /bin/cat >> "$profile" <<'PATH_BLOCK'

# >>> Ashley VPN PATH >>>
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# <<< Ashley VPN PATH <<<
PATH_BLOCK
  fi
else
  print -r -- '请将 ~/.local/bin 加入当前 shell 的 PATH，然后运行 ashleyvpn。'
fi
