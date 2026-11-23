# Routing compatibility and installation-level authorization

Version 0.1.48 (50).

The 0.1.46 data PAC URL was compatible with Chromium but failed the native CFNetwork PAC loader (error 308). This regressed existing model connectivity under GlobalProtect. An actual CFNetworkExecuteProxyAutoConfigurationURL test now covers loading the generated rule from the loopback HTTP PAC service. The service accepts only generated, loopback-only proxy scripts and stays running independently of the menu app.

Runtime routing uses a root-owned, fixed helper through a local Unix socket restricted to the installing user. A first-time administrator authorization installs that helper, its PAC launch daemon, and an installation receipt. Switching never invokes an interactive authorization path once the receipt matches. The receipt binds the grant to the installing user and installation ID. Upgrades preserve the ID and Wi-Fi credentials; uninstall removes the grant and helper. GlobalProtect system service operations reuse the same authenticated component. The helper accepts no arbitrary executables or arbitrary PAC scripts.

Before replacing a network rule, the helper checks that the HTTP PAC service is available and serves the exact intended script. It preserves unrelated active proxies. The previous per-switch AppleScript authorization path is removed.

## Validation

- 27 tests passed, including native CFNetwork loading of the HTTP PAC, invalid PAC rejection, user/installation identity matching, old data-URL migration, and proxy restoration.
- App and helper optimized builds and shell syntax checks passed.
- The earlier installer failed before persisting its helper. The revised installer avoids sudoers entirely and records installation errors. Live installation and VPN transition checks remain pending.
