#!/bin/zsh -f
# Hold one authorized IPv4 host route while Ashley VPN keeps its lease alive.
emulate -L zsh
export LC_ALL=C
umask 077

valid_node() {
  /usr/bin/awk -v address="$1" 'BEGIN {
    if (address !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || split(address, a, ".") != 4) exit 1
    for (i=1; i<=4; i++) if (a[i] > 255 || a[i] != sprintf("%d", a[i])) exit 1
    if (a[1] == 0 || a[1] == 10 || a[1] == 127 || a[1] >= 224 ||
        (a[1] == 100 && a[2] >= 64 && a[2] <= 127) ||
        (a[1] == 169 && a[2] == 254) ||
        (a[1] == 172 && a[2] >= 16 && a[2] <= 31) ||
        (a[1] == 192 && a[2] == 168)) exit 1
  }'
}

route_field() {
  /usr/bin/awk -v field="$1:" '$1 == field { print $2; exit }'
}

owner_is_running() {
  [[ -d "$lease" && ! -L "$lease" ]] || return 1
  local user=$(/bin/ps -p "$owner" -o uid= | /usr/bin/awk '{print $1}')
  local app=$(/bin/ps -p "$owner" -o comm=)
  [[ "$user" == "$owner_uid" && "$app" == '/Applications/Ashley VPN.app/Contents/MacOS/ashley-vpn-menu' ]]
}

owns_route() {
  [[ -n "$installed_gateway" ]] || return 1
  local current=$(/sbin/route -n get -inet "$node" 2>/dev/null) || return 1
  [[ "$(print -r -- "$current" | route_field destination)" == "$node" &&
     "$(print -r -- "$current" | route_field gateway)" == "$installed_gateway" &&
     "$(print -r -- "$current" | route_field interface)" == "$installed_wifi" &&
     ",${${$(print -r -- "$current" | route_field flags)#<}%>}," == *,PROTO2,* ]]
}

release_route() {
  if owns_route; then
    /sbin/route -n delete -host "$node" "$installed_gateway" >/dev/null 2>&1 || return 1
  fi
  installed_gateway=''
  installed_wifi=''
}

sync_route() {
  local wifi current scoped gateway
  wifi=$(/usr/sbin/networksetup -listallhardwareports | /usr/bin/awk '/^Hardware Port: (Wi-Fi|AirPort)$/ {getline; print $2; exit}')
  [[ "$wifi" == en<-> ]] || { release_route; return 1; }
  scoped=$(/sbin/route -n get -ifscope "$wifi" -inet default 2>/dev/null) || { release_route; return 1; }
  gateway=$(print -r -- "$scoped" | route_field gateway)
  if [[ "$gateway" != <->.<->.<->.<-> || "$(print -r -- "$scoped" | route_field interface)" != "$wifi" ]]; then
    release_route
    return 1
  fi
  if owns_route && [[ "$installed_gateway" == "$gateway" && "$installed_wifi" == "$wifi" ]]; then return 0; fi
  release_route || return 1
  current=$(/sbin/route -n get -inet "$node" 2>/dev/null) || return 1
  local interface=$(print -r -- "$current" | route_field interface)
  if [[ "$interface" == "$wifi" ]]; then return 0; fi
  [[ "$interface" == utun<-> ]] || return 1
  /sbin/route -n add -host "$node" "$gateway" -proto2 >/dev/null 2>&1 || return 1
  installed_gateway=$gateway
  installed_wifi=$wifi
}

if [[ "$1" == --hold ]]; then
  shift
  (( EUID == 0 && $# == 3 )) || exit 1
  owner_uid=${SUDO_UID:-}
  node=$1 owner=$2 lease=$3
  [[ "$owner_uid" == <-> && "$owner_uid" != 0 && "$owner" == <-> &&
     "$lease" == /*/ashley-egress-* ]] && valid_node "$node" && owner_is_running || exit 1
  installed_gateway='' installed_wifi=''
  trap release_route EXIT
  trap 'exit 0' HUP INT TERM
  while owner_is_running; do
    sync_route
    /bin/sleep 3
  done
  exit 0
fi

(( $# == 3 && EUID != 0 )) || exit 1
node=$1 owner=$2 lease=$3 owner_uid=$EUID
[[ "$owner" == <-> && "$lease" == /*/ashley-egress-* ]] && valid_node "$node" && owner_is_running || exit 1
print -r -- "让 LibCyber 节点 $node 经 Wi-Fi 连接需要本机管理员授权。"
/usr/bin/sudo -v -p '  本机管理员密码：' || { /bin/rmdir -- "$lease"; exit 1; }
owner_is_running || exit 1
/usr/bin/sudo -n -b /bin/zsh -f "${0:A}" --hold "$node" "$owner" "$lease" </dev/null >/dev/null 2>&1 ||
  { /bin/rmdir -- "$lease"; exit 1; }
