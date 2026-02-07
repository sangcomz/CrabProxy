# CrabProxyMacApp

SwiftUI macOS app that controls the Rust MITM engine (`crab-mitm`) via C ABI (`staticlib`).

## Quick start

```bash
cd CrabProxyMacApp
./Scripts/run-app.sh
```

## Build steps

1. Build Rust static library:

```bash
./Scripts/build-rust.sh
```

2. Build Swift app:

```bash
swift build
```

## Open in Xcode

You can open this Swift package directly in Xcode:

```bash
open Package.swift
```

Before running in Xcode, run `./Scripts/build-rust.sh` once so `libcrab_mitm.a` exists.

## Mobile certificate install portal

In the main app window, click the top-right gear button to open `Settings`.
In `Settings > Device`, you can see:

- Mac LAN IP for iOS/Android proxy host
- Certificate portal URL

When the proxy is running, open this URL from a phone browser configured to use the proxy:

- `http://crab-proxy.local/`

iOS requires one extra step after profile install:
`Settings > General > About > Certificate Trust Settings`.

## Internal CA (managed)

- The app manages CA files automatically at:
  `~/Library/Application Support/CrabProxyMacApp/ca/`
- On first start, it generates `ca.crt.pem` and `ca.key.pem` automatically.

## Listen default

- Listen address is fixed to `0.0.0.0:8888` (not user-editable).
- Ensure macOS firewall allows incoming connections for LAN phone testing.

## Traffic logging behavior

- The app logs only traffic that is actually sent through this proxy.
- Internal lifecycle logs (`start/stop/shutdown`) are hidden from the traffic list UI.
- If you do not see macOS app traffic, that app is likely not using your proxy settings.

## Allowlist (engine-level)

In `Settings > Rules > Allowlist`, you can define what traffic the engine should inspect/rule-process.

- `*.*` or `*` : allow all
- `naver.com` : allow that host and subdomains
- `https://example.com/api` : allow by full URL prefix
- `/graphql` : allow by path prefix

Behavior:

- Non-allowed traffic is still proxied (app does not break browsing).
- But for non-allowed traffic, header/body inspect logs and rule application are skipped.
- Empty allowlist means allow all (default on first launch is `*.*`).

## Platform setup (macOS / iOS / Android)

### macOS

1. Start proxy in CrabProxyMacApp (`0.0.0.0:8888`).
2. In the main window, click `Proxy On` in `macOS Proxy`.
3. Trust the CA certificate:
   - Open `~/Library/Application Support/CrabProxyMacApp/ca/ca.crt.pem`
   - Import into Keychain Access and set trust to `Always Trust` (for HTTPS MITM).
4. Browse with Safari/Chrome; requests should appear in the left traffic panel.

### iOS

1. Start proxy in CrabProxyMacApp.
2. Open `Settings > Device` and copy `Use on iOS/Android`.
3. Connect iPhone/iPad to the same Wi-Fi as Mac.
4. On iOS Wi-Fi details, set HTTP proxy to `Manual`:
   - Server: your Mac LAN IP from `Settings > Device`
   - Port: `8888`
5. In iOS Safari, open:
   - `http://crab-proxy.local/`
6. Install `ios.mobileconfig`.
7. Enable trust:
   `Settings > General > About > Certificate Trust Settings`.

### Android

1. Start proxy in CrabProxyMacApp.
2. Open `Settings > Device` and copy `Use on iOS/Android`.
3. Connect Android device to the same Wi-Fi as Mac.
4. On Wi-Fi advanced settings, set Proxy to `Manual`:
   - Hostname: your Mac LAN IP from `Settings > Device`
   - Port: `8888`
5. In Android browser, open:
   - `http://crab-proxy.local/`
6. Download/install `android.crt` as a CA certificate.
7. Note: many Android apps (especially Android 7+) ignore user-installed CAs, so full HTTPS MITM may work mainly for browsers or debuggable apps configured to trust user CAs.

## Rust staticlib path

The app links to:

- `../crab-mitm/target/debug/libcrab_mitm.a`
- `../crab-mitm/target/release/libcrab_mitm.a`

The package linker settings already include required native dependencies for macOS:

- `Security.framework`
- `CoreFoundation.framework`
- `libiconv`
