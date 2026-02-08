# Crab Proxy

<p align="center">
  <img src="CrabProxyMacApp/Sources/CrabProxyMacApp/Assets.xcassets/AppIcon.appiconset/icon_256.png" alt="Crab Proxy Icon" width="180" />
</p>

Crab Proxy is a traffic inspector for macOS, powered by a Rust MITM engine.
It is designed for app/API debugging on macOS and mobile devices (iOS/Android) on the same LAN.

## What It Does

- Captures HTTP/HTTPS traffic through a local proxy
- Shows requests in time order (left list) with request detail panel (right)
- Supports body inspection toggle (`Inspect Bodies`)
- Supports engine-level allowlist filtering (`*.*`, domain, URL/path prefix)
- Supports rule-based rewrites (map local / status rewrite)
- Includes mobile certificate install portal (`http://crab-proxy.local/`)
- Supports light/dark/system appearance

## App Layout

- Top control bar:
  - `Inspect Bodies`
  - `macOS Proxy` toggle
  - `Start` / `Stop`
  - `Settings`
- Main content:
  - Left: Traffic list + filter + clear
  - Right: Selected request detail

## Settings

- `General`
  - Appearance: `System`, `Light`, `Dark`
- `Rules`
  - Allowlist and rewrite rules
- `Mobile Setup`
  - iOS/Android proxy host instructions
  - Certificate portal guidance

## Mobile Setup (iOS / Android)

1. Start proxy in Crab Proxy.
2. Open `Settings > Mobile Setup` and check your Mac LAN IP.
3. Set phone Wi-Fi proxy to your Mac IP + port `8888`.
4. Open `http://crab-proxy.local/` in phone browser.
5. Install certificate/profile from portal.

iOS: after install, enable trust at:
`Settings > General > About > Certificate Trust Settings`.

Android: some apps ignore user CAs by default; browser/debug builds usually work best.

## Notes

- Listen address is fixed to `0.0.0.0:8888`.
- Internal CA files are managed automatically under:
  `~/Library/Application Support/CrabProxyMacApp/ca/`
- Traffic list hides internal lifecycle logs (`start/stop`) and focuses on request traffic.

## Refactoring Progress (Critical First)

- ~~`S-01` CA private key write path hardened to create key files with owner-only permission (`0600`)~~
- ~~`S-02` FFI log callback safety improved by removing raw-pointer `unsafe Send/Sync` assertion and clarifying callback lifetime contract~~
- ~~`S-03` Swift callback bridge changed from unretained self pointer to retained callback context with explicit teardown~~
- ~~`S-07` body spool directory/file creation hardened with private permissions (`0700` / `0600`)~~
- ~~`P-01` `filteredLogs` changed from per-render computed sort/filter to cached published data rebuilt on data/filter changes~~
