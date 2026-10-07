<div align="center">

# 🦊 FoxyVPN Desktop

<p align="center">
  <img src="assets/images/foxyvpn_logo.jpg" alt="FoxyVPN Desktop" width="120"/>
</p>

<p align="center">
  <b>Secure • Fast • Private VPN Client for Windows</b>
</p>

<br>

<img src="https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011-0078D6?style=flat-square&logo=windows&logoColor=white"/>
<img src="https://img.shields.io/badge/Built%20With-Flutter-02569B?style=flat-square&logo=flutter&logoColor=white"/>
<img src="https://img.shields.io/badge/Language-Dart-0175C2?style=flat-square&logo=dart&logoColor=white"/>
<img src="https://img.shields.io/badge/License-MIT-green?style=flat-square"/>

</div>
<br>

## 🔎 Features

| | |
|---|---|
| 🛡 **System-wide VPN** | A `wintun` adapter plus host-side default-route and DNS takeover |
| 🦊 **Firefox account sign-in** | FxA OAuth + PBKDF2 / HKDF / Hawk, tokens in the Windows credential vault |
| 🌍 **Multiple servers** | Location picker fed by Mozilla's Remote Settings, with edge failover |
| 🔌 **Proxy-only mode** | Local proxy on `127.0.0.1:1080` — no adapter, no admin rights needed |
| 🖥 **Windows system proxy** | Registers the local port as the machine proxy, restores it on disconnect |
| 🔗 **Upstream proxy chaining** | Dials Fastly (and the control plane) through an existing SOCKS5/HTTP proxy |
| 🔐 **Encrypted DNS** | DNS-over-HTTPS resolution plus `mapdns` fake-IP handling |
| 🚪 **Exit verification** | Confirms your public IP changed before reporting "connected" |
| 📊 **Live stats + logs** | Speed counters and an in-app log viewer |
| 🌗 **Dark / light / system theme** | |
| 📱 **Phone-sized window** | Fixed 360×800 (9:20), non-resizable — same layout as the Android UI |

> [!NOTE]
> **Not (yet) on Windows:** per-app split tunneling. Windows has no equivalent
> of Android's `VpnService.addDisallowedApplication`, so it is intentionally
> left out rather than faked.

<br>

## 📸 Screenshots

> [!TIP]
> Screenshots are not committed yet. Drop captures into `docs/screenshots/`
> (`home.png`, `servers.png`, `settings.png`, `logs.png`) and uncomment the
> gallery block at the bottom of this file — the markup is already prepared.

<!--
<table>
  <tr>
    <td><img src="docs/screenshots/home.png" alt="Home / connect" width="220"/></td>
    <td><img src="docs/screenshots/servers.png" alt="Location list" width="220"/></td>
    <td><img src="docs/screenshots/settings.png" alt="Settings" width="220"/></td>
    <td><img src="docs/screenshots/logs.png" alt="Logs" width="220"/></td>
  </tr>
</table>
-->

<br>

## 🧿 How it works

```
Windows apps
     │
     ▼
wintun adapter (10.8.0.2, MTU 8500)   ◄── default route + DNS moved here by the app
     │
     ▼
hev-socks5-tunnel (child process)     ◄── mapdns fake-IP 100.64.0.0/10, DNS at 198.18.0.2
     │  SOCKS5 / HTTP
     ▼
LocalSocks5Server (Dart, 127.0.0.1:1080)   ◄── mixed-protocol port
     │  one HTTP/2 stream per connection
     ▼
H2UpstreamSession (TLS + ALPN h2 + Bearer proxy pass)
     │
     ▼
Fastly edge  ──►  Internet
```

| Path | Role |
|---|---|
| `lib/vpn/vpn_controller.dart` | Orchestrator: connect flow, watchdog, edge rotation, proxy-pass renewal, exit check, stats. Port of Android's `FoxyVpnService`. |
| `lib/vpn/route_manager.dart` | The Windows-specific part: bypass routes, default-route takeover, DNS swap, ordered restore |
| `lib/vpn/local_socks5_server.dart` | Mixed SOCKS5 **and** HTTP frontend on one port |
| `lib/vpn/system_proxy_manager.dart` | `HKCU\...\Internet Settings` + wininet broadcast |
| `lib/vpn/h2_upstream_session.dart` | HTTP/2 CONNECT streams to the edge, with proxy chaining |
| `lib/data/` | FxA auth, Guardian proxy passes, server list, Fastly challenge solver, settings, secure storage |
| `lib/ui/` | Home, locations, login, settings, logs |

<details>
<summary><b>Why the app has to touch the route table itself</b></summary>

<br>

`hev-socks5-tunnel` creates the adapter but deliberately does **not** modify
routes or DNS on Windows, so the app does that host-side:

- **Bypass first.** Before the engine starts it resolves the control-plane
  hosts, the DoH servers, the chosen edge and the upstream-proxy host, and
  installs `/32` bypass routes through the *physical* gateway. Without this the
  app's own connection would loop back into the tunnel.
- **Then take over.** Once the adapter is up, the IPv4 default route moves onto
  wintun and system DNS points at the engine's mapdns listener (or your custom
  server).
- **Literal-IP edge dials.** Under takeover the OS resolver returns fake IPs,
  so the edge and proxy connections always use a pre-cached literal address.
- **Clean teardown.** Disconnecting — or closing the window — restores the
  original default route and DNS servers, in order, before the engine stops.

IPv6 is not taken over, because the adapter is IPv4-only.

</details>

<br>

## 🚀 How to use

1. **Get a Firefox account** — create one for free at
   [accounts.firefox.com](https://accounts.firefox.com/signup).
2. **Launch `FoxyVPN.exe`** (it asks for administrator rights once).
3. **Sign in** with that account's email and password.
4. **Pick a location** and press the power button.

> [!IMPORTANT]
> Once the free 50 GB monthly allowance is used up, connections stop working
> until it resets. The app surfaces that as a quota error rather than silently
> retrying.

<br>

## 🗃 Requirements

- Windows 10 / 11, x64
- **Administrator rights** for full-VPN mode (creating the adapter and editing
  the route table). Proxy-only mode needs none.
- For building: Flutter for Windows desktop, and the Visual Studio *Desktop
  development with C++* workload

<br>

## ⚙️ Build

```bash
git clone https://github.com/M-RTZ1/FoxyVPN.git
cd FoxyVPN

flutter pub get
flutter build windows --release
```

Output: `build\windows\x64\runner\Release\`.

Checks before you commit:

```bash
flutter analyze
flutter test
```

<br>

## 🪟 Two things to know before connecting

### 1. Administrator rights

The app declares `requireAdministrator` in
`windows\runner\runner.exe.manifest`, because creating a wintun adapter and
editing the route table need elevation. If you only want proxy-only mode
without elevation, delete the `trustInfo` block and the `/MANIFESTUAC:NO` line
in `windows\runner\CMakeLists.txt`.

For `flutter run`, launch it from an **already elevated** terminal — otherwise
Windows shows a UAC prompt for the child process and the debugger cannot attach
through it. The release exe prompts once on double-click, as usual.

### 2. The tunnel engine is already bundled

The tun2socks engine is the native binary from
[heiher/hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel/releases).
A copy of **v2.18.0** (`hev-socks5-tunnel.exe`, `wintun.dll`, `msys-2.0.dll`)
lives in `third_party\hev-socks5-tunnel\bin\`, and the CMake build copies it
next to the app for every Debug and Release build — so a fresh `git clone`
works without a manual download step.

To upgrade: extract a newer `hev-socks5-tunnel-win64.zip` over those three
files and rebuild. Settings → *hev-socks5-tunnel.exe path* can also point at
any other copy. If the files are missing, full-VPN connect reports
"hev-socks5-tunnel.exe was not found" while proxy-only mode keeps working.

<br>

## 🌐 Three ways to route traffic

### Full-VPN mode *(default)*

Needs admin. Takes over the default route and DNS as described above, so every
app on the machine goes through the tunnel without configuration.

### Proxy-only mode

Settings → **Proxy-only mode**. The app just runs the local proxy at
`127.0.0.1:1080` (port configurable) and you point browsers or apps at it
manually. No wintun, no native binary, no elevation.

The port is **mixed-protocol**: it speaks SOCKS5 *and* plain HTTP proxying
(`CONNECT` plus absolute-URI requests) on the same socket — which is exactly
what Windows' system proxy expects.

### Windows system proxy

Settings → **Set as Windows system proxy**. While connected, the app writes
`ProxyEnable` / `ProxyServer` (`127.0.0.1:<port>`) to the Internet Settings key
and broadcasts the change through wininet, so browsers and every other
proxy-aware app use the tunnel with no per-app setup. The previous values are
restored on disconnect and when the window closes.

If the app is killed abruptly, reset it by hand:

```bat
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f
```

<br>

## 🔗 Chaining through another proxy

Settings → **Use an upstream proxy** makes the app reach the Fastly edges
through an existing SOCKS5 or HTTP proxy (optional credentials are stored in
the Windows credential vault). Sign-in, Guardian, the server list and DoH
requests chain through it too, so the whole program works on networks that
require a proxy.

- **Copy from Windows system proxy** fills the fields from the machine's
  current proxy setting.
- In full-VPN mode the proxy host is added to the bypass route set, so the
  chain leaves through the physical gateway instead of looping into wintun.
- **Known limitation:** the control-plane half cannot attach proxy credentials
  (a `dart:io` `findProxy` limitation). Use a no-auth proxy for that path, or
  put the credentials on the edge connection.

<br>

## 🔧 Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `the tunnel process exited immediately` | `wintun.dll` missing next to the binary, or the app is not elevated |
| Connects, but nothing loads | Check the **Logs** tab; if the upstream dial fails, pick another location or clear a pinned edge |
| `route add` failures | Some security software blocks route manipulation — the app logs a warning and may still work, more slowly |
| Traffic still looks direct | Another VPN or a static route is winning — the app's takeover assumes it owns the IPv4 default route |
| Proxy settings stuck after a crash | Run the `reg add` command above |
| Quota error | The 50 GB monthly allowance is spent; it resets with your billing month |

<br>

## 📱 Differences from the Android app

- No per-app split tunneling.
- Speed statistics come from the in-app SOCKS5/HTTP proxy counters instead of
  the Android `VpnService` stats.
- The exit check uses a plain-HTTP `ip-api.com` request over a tunnel stream
  rather than the Cloudflare HTTPS trace.
- Exit-check and DNS settings live under the Settings tab — same options as
  Android, minus app exclusion.

<br>

## 📝 To-Do

- [x] Route/DNS takeover, so the bundled engine actually carries traffic.
- [x] Mixed-protocol local port, Windows system proxy, upstream chaining.
- [x] App icon and in-app logo.
- [ ] Installer and auto-update.
- [ ] IPv6 support (needs an IPv6-capable tunnel path).
- [ ] Per-app split tunneling on Windows.
- [ ] HTTP/3 implementation *(not planned yet)*.

<br>

## ✍️ Acknowledgements

- [firefox-vpn-client](https://github.com/UjuiUjuMandan/firefox-vpn-client) —
  the Go reference client the original app is a port of
- [FoxyVPN](https://github.com/Vauth/FoxyVPN) — the Android app this is ported
  from
- [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) — the native
  tun2socks engine
- [wintun](https://www.wintun.net/) — the userspace tunnel driver
- [Flutter](https://flutter.dev) and [dart:io / package:http2](https://pub.dev) —
  the desktop UI and the HTTP/2 stack

<br>

## 🛠 Contributing

Contributions are welcome — open an issue first for anything bigger than a typo,
and send `flutter analyze` / `flutter test` results clean with your pull request.

<br>

## ⚠️ Disclaimer

Unofficial client. Not affiliated with, endorsed by, or supported by Mozilla or
Fastly. It uses the same public endpoints and free entitlement the Firefox
browser's built-in VPN uses; treat account credentials accordingly and review
the code before trusting it with your traffic.

<br>

## 📄 License

This project is licensed under the MIT License — see the
[LICENSE](LICENSE) file for details.
