# New chat workspace initialization over the selected proxy

- Version: 0.1.46 (48).
- Desktop logs reported `ERR_CONNECTION_RESET` for `/settings/user` and account initialization endpoints while existing chats remained usable.
- The old inline-only PAC was ignored by a Chromium system-proxy probe, which resolved requests as `DIRECT`. macOS Chromium reads `ProxyAutoConfigURLString`: https://github.com/chromium/chromium/blob/main/net/proxy_resolution/proxy_config_service_mac.cc.
- Supply the same generated PAC as inline JavaScript and a base64 data URL. Recognize the URL when CFNetwork omits the inline field in its effective settings.
- GlobalProtect exposes its primary service (`gpd.pan`) only in the dynamic store. Apply domain rules to that service through a fixed, administrator-authorized helper. Validate helper input against the generated loopback-only rule, preserve earlier settings, and leave unrelated proxy configurations untouched.
- Preserve the installed app's resources, installation identity, Wi-Fi credentials and route preferences during the local update. Restart only Ashley VPN; keep the chat app and GlobalProtect running.

## Validation

- All 25 existing and updated tests passed, including PAC interpretation, migration, restoration, external-change protection and GlobalProtect legacy configuration adoption.
- Optimized arm64 application compilation and ad-hoc signature verification passed.
- A fresh isolated Chromium process, using system settings without proxy command-line overrides, resolved the OpenAI request through `127.0.0.1:8890` and received HTTP 401 from the unauthenticated `/settings/user` endpoint. This confirms transport; it does not verify account access.
- In-app new-chat interaction remains a manual verification because computer control of the chat application is unavailable. No chat app restart was performed.
