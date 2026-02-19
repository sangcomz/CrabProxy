# Crab Proxy

<p align="center">
  <img src="CrabProxyMacApp/Sources/CrabProxyMacApp/Assets.xcassets/AppIcon.appiconset/icon_256.png" alt="Crab Proxy Icon" width="180" />
</p>

Language: **English (default)** | [한국어](README.ko.md)

## English (Default)

Crab Proxy is a macOS traffic inspector powered by the `crab-mitm` Rust engine.
It is built for app/API debugging on macOS and on mobile devices in the same LAN.

## Highlights

- Live capture for HTTP/HTTPS proxy traffic.
- Sidebar scopes: `All Traffic`, `Pinned`, `Apps`, `Domains`.
- App-based traffic grouping with best-effort app name/icon detection.
- Independent traffic scopes:
  - Click a domain to see traffic in that domain.
  - Click an app to see traffic from that app.
- URL search (`Show only traffic URLs containing...`).
- Status filters (`All`, `1xx`, `2xx`, `3xx`, `4xx`, `5xx`).
- Detail tabs: `Summary`, `Headers`, `Body`, `Query`.
- Context actions: `Replay`, `Add to Allowlist`, `Add to Map Local`, `Add to Rewrite`.
- Rules UI: `Allowlist`, `Map Local` (file/text), `Status Rewrite`.
- Mobile setup:
  - LAN proxy endpoint guidance.
  - Device IP allowlist + approval prompt.
  - Certificate portal (`http://crab-proxy.local/`).
- Advanced settings:
  - `Inspect Bodies`
  - Network throttling (presets/custom, optional selected-host mode)
  - Transparent proxy mode
- Appearance modes: `System`, `Light`, `Dark`.

## Project Structure

- `CrabProxyMacApp`: SwiftUI macOS app.
- `crab-mitm`: Rust proxy engine + C FFI.

## Build and Run (Development)

1. Build the Rust static library:

```bash
cargo build --manifest-path crab-mitm/Cargo.toml
```

2. Run the macOS app:

```bash
swift run --package-path CrabProxyMacApp CrabProxyMacApp
```

Optional release build:

```bash
cargo build --release --manifest-path crab-mitm/Cargo.toml
swift build -c release --package-path CrabProxyMacApp
```

## Quick Start

1. Launch the app and press `Start`.
2. (Optional) Enable `macOS Proxy` to route this Mac's traffic through Crab Proxy.
3. For HTTPS decryption:
   - Install/trust the CA in `Settings > General`.
   - Add target patterns in `Settings > Rules > Allowlist (SSL Proxying)`.
4. Use `Apps` or `Domains` in the left sidebar to scope traffic.
5. For mobile, open `Settings > Mobile` and configure phone proxy with the shown endpoint.
6. On the phone, open `http://crab-proxy.local/` to install CA/profile.

## HTTPS MITM Behavior

- CA is required for HTTPS MITM.
- Allowlist rules are also required for HTTPS MITM targets.
- If CA or allowlist is missing, HTTPS is tunneled (not decrypted).

## Notes

- Default proxy port is `8888`.
- Internal CA files are stored at:
  `~/Library/Application Support/CrabProxyMacApp/ca/`
- This is a debugging tool. Do not run it as an open proxy on untrusted networks.
