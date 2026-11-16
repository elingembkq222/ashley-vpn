check_globalprotect() {
  if [ ! -x /Applications/GlobalProtect.app/Contents/MacOS/GlobalProtect ] ||
     [ ! -x /Applications/GlobalProtect.app/Contents/Resources/PanGPS ] ||
     [ ! -r /Library/LaunchAgents/com.paloaltonetworks.gp.pangpa.plist ] ||
     [ ! -r /Library/LaunchAgents/com.paloaltonetworks.gp.pangps.plist ]; then
    printf '%s\n' '未检测到完整的集团 GlobalProtect 客户端。请先通过公司渠道安装 GlobalProtect，再运行 Ashley VPN 安装脚本。' >&2
    return 1
  fi
}
