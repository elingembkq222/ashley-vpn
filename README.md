# Ashley VPN

A macOS menu bar app for connecting to the company VPN through GlobalProtect.

## Prerequisites

| Required | Prerequisite | What to install or prepare |
| :---: | --- | --- |
| ✅ | macOS 12 or later | Update macOS if needed. |
| ✅ | Company GlobalProtect client | Install it through company IT. |
| ✅ | Company VPN client certificate and private key (to connect) | Import the IT-issued certificate and private key into the System keychain. The private key needs access grants for `GlobalProtect`, `PanGPS`, and `com.apple.identity.export`. |
| ✅ | Xcode Command Line Tools | Run `xcode-select --install` if the tools are missing. |
| ✅ | Write access to `/Applications` | Use a macOS account with permission to install apps there. |

## Install

```sh
curl -fsSL 'https://raw.githubusercontent.com/elingembkq222/ashley-vpn/main/bootstrap.sh' | bash
```

Run the same command to update or repair VPN certificate permissions. If any access grants listed above are missing, the installer prompts for administrator authentication, adds the missing grants, and verifies them.

If the private key was inadvertently set to prompt for a password on every use, rerun the pipeline with `bash -s -- --restore-keychain-prompt` in place of `bash`.

## Connect

Open a Terminal window and run `ashleyvpn`. Use the menu bar or floating desktop icon to connect or disconnect. Terminal opens when Wi-Fi selection, a password, or administrator approval is needed. Connection and shutdown progress appear by the floating icon and on the menu bar. The icon turns orange when the VPN tunnel is up.

## Uninstall

Run this from the macOS account that installed Ashley VPN.

```sh
curl -fsSL 'https://raw.githubusercontent.com/elingembkq222/ashley-vpn/main/uninstall.sh' | zsh -f
```

This removes Ashley VPN, its settings, and its saved Wi-Fi credentials. GlobalProtect remains installed.
