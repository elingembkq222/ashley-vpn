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

On macOS 14 or later, the signed networking extension applies the **Codex 流量** menu selection to new TCP connections from the running Codex desktop model process. On first use, approve the Ashley VPN extension and network configuration when macOS asks. The menu reports when the extension acknowledges the selection. An existing model stream can keep its original connection until it reconnects.

Ashley scans clients, proxy listeners and system VPN profiles at startup and every minute. Select LibCyber to use its local HTTP CONNECT or SOCKS5 listener, or select a connected system VPN to bind outgoing connections to that service’s tunnel interface. Both modes require a working upstream. If it is unavailable, the selected path fails until connectivity returns. Codex UDP on port 443 is declined while a route is selected so clients supporting TCP can retry. Choose **无** to return new connections to the system default. Other applications use their usual settings.

The source installer can build the extension on an authorized signing Mac. Set `ASHLEY_SIGN_IDENTITY` to a Developer ID Application signing identity, `ASHLEY_HOST_PROFILE` and `ASHLEY_PROVIDER_PROFILE` to the two provisioning profiles, and `ASHLEY_NOTARY_PROFILE` to a notarytool keychain profile. The app IDs are `com.ashley.vpn.companion` and `com.ashley.vpn.companion.routing`. Both profiles need the app-proxy-provider-systemextension capability. The host also needs System Extension installation permission, and the extension uses the app group `<TeamID>.com.ashley.vpn.companion.routing`. The installer signs, notarizes and staples the app before replacing the installed bundle.

Local builds offer **OpenAI 域名代理** for local HTTP and SOCKS listeners. The selected proxy applies to new system-proxy-aware requests for chatgpt.com, openai.com, oaistatic.com, oaiusercontent.com and their subdomains, including requests from other apps. The rule follows the active network service independently of GlobalProtect. Choose **无** to restore the previous settings. An existing active proxy configuration is preserved.

The domain configuration includes both a native inline PAC script and an equivalent data URL. Chromium-based desktop clients read the PAC URL on macOS; supplying only the inline script leaves their workspace and account initialization requests on the default network path. The data URL needs no PAC server. Upgrades migrate the earlier inline-only configuration while keeping its original settings backup.

GlobalProtect can publish the primary VPN service only in macOS's dynamic network store. Applying or restoring its domain rule requests macOS administrator authorization through the installed app's fixed helper. Existing unrelated proxy configurations remain protected. Native network services continue to use the standard network preferences authorization.

## Uninstall

Run this from the macOS account that installed Ashley VPN.

```sh
curl -fsSL 'https://raw.githubusercontent.com/elingembkq222/ashley-vpn/main/uninstall.sh' | zsh -f
```

This removes Ashley VPN, its settings, and its saved Wi-Fi credentials. GlobalProtect remains installed.
