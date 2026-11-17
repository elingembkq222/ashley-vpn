# Ashley VPN

A macOS menu bar app for connecting to the company VPN through GlobalProtect.

## Prerequisites

| Required | Prerequisite | What to install or prepare |
| :---: | --- | --- |
| ✅ | macOS 12 or later | Update macOS if needed. |
| ✅ | Company GlobalProtect client | Install it through company IT. |
| ✅ | Xcode Command Line Tools | Run `xcode-select --install` if the tools are missing. |
| ✅ | Write access to `/Applications` | Use a macOS account with permission to install apps there. |

## Install

```sh
curl -fsSL 'https://raw.githubusercontent.com/elingembkq222/ashley-vpn/main/bootstrap.sh' | bash
```

Run the same command to update or repair VPN certificate permissions. If the VPN private key is missing a GlobalProtect, PanGPS, or `com.apple.identity.export` grant, the installer prompts for administrator authentication, adds the missing grants, and verifies them.

If the private key was inadvertently set to prompt for a password on every use, rerun the pipeline with `bash -s -- --restore-keychain-prompt` in place of `bash`.

## Connect

Open a new Terminal window and run `ashleyvpn`. Use the menu bar icon or click the floating desktop icon to connect or disconnect. Follow the Terminal prompts to select Wi-Fi and complete GlobalProtect sign-in when needed. The icon turns orange when the VPN tunnel is up.

## Uninstall

Run this from the macOS account that installed Ashley VPN.

```sh
curl -fsSL 'https://raw.githubusercontent.com/elingembkq222/ashley-vpn/main/uninstall.sh' | zsh -f
```

This removes Ashley VPN, its settings, and its saved Wi-Fi credentials. GlobalProtect remains installed.
