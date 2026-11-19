# Match the client executables by installed path, including PanGPS started by
# either the user LaunchAgent or the system daemon. The macOS extension is separate.
_gp_processes() {
  LC_ALL=C /bin/ps -axww -o pid= -o ruid= -o comm= |
    /usr/bin/awk '
      $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
        pid = $1
        uid = $2
        sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "")
        if ($0 == "/Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect" ||
            $0 == "/Applications/GlobalProtect.app/Contents/Resources/PanGPS") print pid, uid
      }
    '
}

_gp_kill_root_processes() {
  _gp_processes | while read -r gp_pid gp_uid; do
    if [ "$gp_uid" = 0 ] &&
       _gp_processes | /usr/bin/grep -Fqx -- "$gp_pid 0"; then
      /bin/kill -KILL "$gp_pid" 2>/dev/null || true
    fi
  done
}
