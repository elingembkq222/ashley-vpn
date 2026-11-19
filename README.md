# Ashley VPN

A macOS menu bar app for connecting to the company VPN through GlobalProtect.

## Prerequisites

| Required | Prerequisite | What to install or prepare |
| :---: | --- | --- |
| ✅ | macOS 12 or later | Update macOS if needed. |
| ✅ | Company GlobalProtect client | Install it through company IT. |
| ✅ | Company VPN client certificate and private key (to connect) | Import the IT-issued certificate and private key into the System keychain. The private key needs access grants for `GlobalProtect`, `PanGPS`, and `com.apple.identity.export`. |
| ✅ | Apple Swift **6.2.4 or later** and macOS SDK **26.2 or later** | Install or update Xcode Command Line Tools for your macOS. Both minimum versions are mandatory. |
| ✅ | Write access to `/Applications` | Use a macOS account with permission to install apps there. |

## Install

The installer checks the active Swift compiler and macOS SDK before building or changing Ashley VPN. If either mandatory version is missing, too old, or cannot be identified, it displays the detected versions and blocks the build. These checks also apply to `--check` and certificate repair modes.

For an existing default Command Line Tools installation, an interactive terminal can offer an automatic update. The installer finds the latest eligible stable Command Line Tools package available from Apple, shows its name, and asks you to confirm. macOS requests administrator authorization through `sudo`; Ashley VPN does not read or store your password. Only that package is installed. Both versions are checked again before installation continues. Cancelling, authorization failure, an unavailable update, or versions still below the requirements stop the installation. `--check` never offers or performs updates. Full Xcode installations and custom toolchain selections need manual updates.

If Command Line Tools are missing, run `xcode-select --install`. To update an existing installation, use **System Settings → General → Software Update**. If the active tools come from the full Xcode app, update Xcode and select the new version under **Xcode → Settings → Locations → Command Line Tools**. Install a release compatible with your macOS; update macOS first if necessary. Verify both versions before retrying:

```sh
xcrun swiftc --version
xcrun --sdk macosx --show-sdk-version
```

Then install Ashley VPN:

```sh
curl -fsSL 'https://raw.githubusercontent.com/elingembkq222/ashley-vpn/main/bootstrap.sh' | bash
```

Run the same command to update or repair VPN certificate permissions. If any access grants listed above are missing, the installer prompts for administrator authentication, adds the missing grants, and verifies them.

If the private key was inadvertently set to prompt for a password on every use, rerun the pipeline with `bash -s -- --restore-keychain-prompt` in place of `bash`.

## Connect

Open a Terminal window and run `ashleyvpn`. Use the menu bar or floating desktop icon to connect or disconnect. Terminal opens when Wi-Fi selection, a password, or administrator approval is needed. Connection and shutdown progress appear by the floating icon and on the menu bar. The icon turns orange when the VPN tunnel is up.

Choose **退出** in the menu bar or confirm after double-clicking the floating icon to stop GlobalProtect and close Ashley VPN. A regular disconnect offers Wi-Fi selection. Cancelling an in-progress VPN operation stops GlobalProtect. If its client processes remain after the launch services stop, Ashley VPN ends those processes and checks that they have exited.

During a connection requested in Ashley VPN, a running but disconnected GlobalProtect client may need its **Connect** button pressed. Ashley VPN can press it with macOS Accessibility permission. Approve **Ashley VPN** under System Settings → Privacy & Security → Accessibility when prompted. Complete any sign-in or MFA in GlobalProtect.

Ashley VPN scans macOS VPN profiles and local proxy routes at startup and every minute. In the menu bar, choose a fallback under **Codex 流量**. Ashley VPN remembers the selection and checks the route after the company VPN disconnects. Choose **无** to leave routing to your normal network settings. Ashley VPN leaves the running Codex process open.

For LibCyber or another local proxy, enable **System Proxy** in that app. In Codex, add `respect_system_proxy = true` under `[features]` in `~/.codex/config.toml`. Codex reads this option the next time you open it. Ashley VPN checks the effective macOS proxy for `chatgpt.com`. A macOS VPN uses the routes from its system profile and can affect other apps on the Mac.

## Uninstall

Run this from the macOS account that installed Ashley VPN.

```sh
curl -fsSL 'https://raw.githubusercontent.com/elingembkq222/ashley-vpn/main/uninstall.sh' | zsh -f
```

This removes Ashley VPN, its settings, and its saved Wi-Fi credentials. GlobalProtect remains installed.
