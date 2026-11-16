# Ashley VPN

Ashley VPN 是独立的 macOS 菜单栏应用。它通过本机已有的公司 GlobalProtect 客户端开启和关闭集团 VPN。

## 一条命令安装

需要 macOS 12 或更新版本、已按公司流程安装的 GlobalProtect 客户端、Xcode Command Line Tools，以及能写入「应用程序」目录的账号。安装脚本先检查 GlobalProtect，缺少时会停止并提示先安装客户端。

```sh
curl -fsSL 'https://raw.githubusercontent.com/elingembkq222/ashley-vpn/main/bootstrap.sh' | bash
```

下载无需 GitHub 登录。安装脚本保存启动命令到 `~/.local/bin/ashleyvpn`，并将这个目录加入 zsh 或 Bash 新终端的 PATH。

## 一条命令启动

打开新的终端窗口，运行：

```sh
ashleyvpn
```

单击顶部菜单栏的爪印可以打开 VPN 菜单。桌面右下角的悬浮爪印可以拖动，单击直接切换 VPN。隧道建立后爪印为橙色，关闭后为灰色，连接或关闭过程中光点会沿外圈移动。此时再点一下桌面爪印会取消本次终端操作，图标随后按实际 VPN 状态显示。可以用菜单栏的「显示桌面图标」恢复已隐藏的悬浮图标。已下载源码时，也可本地运行 `./install.sh`，或以 `./install.sh --check` 只检查 GlobalProtect。

## 使用

- **开启 VPN**：加入小写 `officewifi`，等网络就绪，再启动 GlobalProtect。需要 Wi-Fi 密码时在终端输入，字符不会回显。完成 GlobalProtect 的登录后，终端等到确认隧道建立才报告连接成功。
- **关闭 VPN**：停止 GlobalProtect，再切回大写 `OfficeWiFi`。本次安装第一次需要停止运行中的 GlobalProtect 时，终端由 macOS `sudo` 提示验证一次本机管理员密码。已经停止的 VPN 会跳过关闭，已在 `OfficeWiFi` 时也会跳过切网。
- 连接和关闭都在独立的终端窗口显示进度。命令完成或取消后，这个窗口自动关闭。一次只执行一个操作。

Ashley VPN 在钥匙串中为两个 Wi-Fi 分别保存连接成功的凭据。每次运行安装脚本都会生成新的安装 ID，新安装不会使用前一次安装的 Wi-Fi 记录。macOS 只记住停止指定 GlobalProtect 服务的授权，不会让应用读取或保存本机管理员密码。升级或重装后，旧授权失效。
