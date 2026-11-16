# Ashley VPN

Ashley VPN 是独立的 macOS 菜单栏应用。它通过本机已有的公司 GlobalProtect 客户端开启和关闭集团 VPN。

## 下载并安装

需要 macOS 12 或更新版本、公司 GlobalProtect 客户端、Xcode Command Line Tools，以及能写入「应用程序」目录的账号。缺少 Xcode Command Line Tools 时可先运行 `xcode-select --install`。

在 macOS 终端运行以下命令即可下载并安装。下载无需 GitHub 登录。

```sh
curl -fsSL 'https://raw.githubusercontent.com/elingembkq222/ashley-vpn/main/bootstrap.sh' | bash
```

安装命令会检查本机版本。版本一致时保留当前安装并继续检查证书权限。版本不同时，先构建并验证新版，再自动移除旧应用并安装新版。

需要安装时，终端会显示 macOS 版本、GlobalProtect、Xcode 命令行工具和「应用程序」目录的检查结果。遇到第一项失败会停止安装，并显示处理方法。看到「Ashley VPN 已安装」后，即可打开新终端启动。安装脚本将 `ashleyvpn` 放到 `~/.local/bin`，并为新的 zsh 或 Bash 终端配置 PATH。

安装、升级或确认已是最新版后，终端都会检查系统钥匙串中的集团 VPN 客户端证书。唯一匹配的证书私钥缺少 GlobalProtect 或 PanGPS 的访问权限时，终端会提示管理员验证，然后将缺少的应用加入该私钥现有的访问控制列表。权限齐全、证书缺失或匹配到多张证书时会显示检查结果。若授权取消或失败，可在终端再次运行同一条安装命令。

## 一条命令启动

打开新的终端窗口，运行：

```sh
ashleyvpn
```

单击顶部菜单栏的爪印可以打开 VPN 菜单。桌面右下角的悬浮爪印可以拖动，单击直接切换 VPN。隧道建立后爪印为橙色，关闭后为灰色，连接或关闭过程中光点会沿外圈移动。此时再点一下桌面爪印会取消本次终端操作，图标随后按实际 VPN 状态显示。可以用菜单栏的「显示桌面图标」恢复已隐藏的悬浮图标。已下载源码时，也可本地运行 `./install.sh`，或运行 `./install.sh --check` 只检查安装条件。

## 使用

- **开启 VPN**：有可用的有线网络时直接进入 GlobalProtect 启动流程，否则先在终端选择 Wi-Fi，也可以沿用已连接的网络。每次安装后首次开启时，若 GlobalProtect 正在运行，先关闭现有服务再启动。完成 GlobalProtect 登录后，终端等到确认隧道建立才报告连接成功。
- **关闭 VPN**：停止 GlobalProtect。有线网络可用或 macOS 系统 VPN 已连接时保留当前网络，其他情况下可在终端选择 Wi-Fi，可以选择「保留当前网络」。本次安装第一次需要停用或卸载 GlobalProtect 的系统服务时，终端由 macOS `sudo` 提示验证一次本机管理员密码。已经停止的 VPN 会跳过关闭。
- 连接和关闭都在独立的终端窗口显示进度。命令完成或取消后，这个窗口自动关闭。一次只执行一个操作。

用 ↑/↓ 移动光标，按回车确认。按 Tab 进入搜索，输入名称的一部分即可筛选。按 Esc 清除搜索，再按 Esc 取消选择。列表优先显示扫描到的 `officewifi` 和 `OfficeWiFi`，其他网络按名称排序。若 macOS 未提供附近的网络名称，列表会显示已保存的网络，并可选「输入隐藏网络名称」输入完整名称。Wi-Fi 密码在终端输入，字符不会回显。

仅连接有线网络且 macOS 系统 VPN 已连接时，开启集团 VPN 会提示先在「系统设置 → VPN」手动关闭系统 VPN，再重试。

Ashley VPN 在钥匙串中按 Wi-Fi 名称分别保存连接成功的凭据。首次安装或升级时会生成新的安装 ID。升级后会清理旧版本保存的 Wi-Fi 凭据和设置，并使旧停止授权失效。macOS 只记住停止指定 GlobalProtect 服务的授权。如果本机无法保存免密授权，管理员验证通过后仍可完成本次关闭，下次需要停止系统服务时会再次验证。

## 卸载

在安装 Ashley VPN 的 Mac 账户下运行：

```sh
curl -fsSL 'https://raw.githubusercontent.com/elingembkq222/ashley-vpn/main/uninstall.sh' | zsh -f
```

脚本会退出 Ashley VPN、将应用移到废纸篓，并清理启动命令、应用设置和本次安装保存的 Wi-Fi 凭据。移除应用后，本次安装的停止授权失效。公司 GlobalProtect 客户端和当前网络连接会保留。
