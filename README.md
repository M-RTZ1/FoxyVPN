# FoxyVPN for Windows (Flutter)

Windows port of the FoxyVPN Android app, built with Flutter. The window is
phone-sized (360×800, a 9:20 aspect ratio) and non-resizable, so the UI
feels like the Android app.

Like the Android version, this is **not** WireGuard: your traffic is carried
over HTTP/2 CONNECT streams through Fastly edge servers, authenticated with
short-lived Guardian "proxy passes" minted from a Firefox Account OAuth
token. It uses Mozilla's free 50 GB/month entitlement.

## How it works

```
apps ──► wintun adapter ──► hev-socks5-tunnel (child process)
                                  │  SOCKS5
                                  ▼
                      LocalSocks5Server (Dart, 127.0.0.1:1080)
                                  │  one HTTP/2 stream per connection
                                  ▼
                      H2UpstreamSession (TLS/ALPN h2 + Bearer proxy pass)
                                  ▼
                            Fastly edge ──► Internet
```

- `lib/vpn/vpn_controller.dart` — orchestrator (connect flow, watchdog,
  edge failover, proxy-pass renewal, exit check, speed stats). Port of
  Android's `FoxyVpnService`.
- `lib/data/` — FxA auth (PBKDF2/HKDF/Hawk), Guardian client, Remote
  Settings server list, Fastly "client challenge" solver, settings,
  secure token storage.
- hev-socks5-tunnel creates the wintun adapter but deliberately does **not**
  touch routes or DNS on Windows — `lib/vpn/route_manager.dart` performs that
  host-side work: before the engine starts it resolves the control-plane
  hosts, DoH servers, the selected edge and the upstream-proxy host and
  installs /32 bypass routes via the physical gateway; once the adapter is
  up it moves the IPv4 default route onto wintun and points system DNS at the
  engine's mapdns listener (or your custom DNS server). Disconnecting (or
  closing the app) restores the original default route and DNS servers.
- Edge dials always use a literal IP (pinned edge, DoH-resolved, or
  pre-tunnel resolution) so the app's own upstream connection never loops
  back through the tunnel. IPv6 is not taken over (the adapter is IPv4-only).
- DNS: mapdns fake-IP resolution (100.64.0.0/10) inside hev-socks5-tunnel,
  queried through the OS at 198.18.0.2; or a custom DNS server setting.

## Building

Requires Flutter for Windows desktop and the Visual Studio "Desktop
development with C++" workload:

```
flutter pub get
flutter build windows
```

Output: `build\windows\x64\runner\Release\`.

## Running — two things you must do

### 1. Administrator rights

The app requests `requireAdministrator` in
`windows\runner\runner.exe.manifest` because creating a wintun adapter and
editing the route table need elevation. Remove the `trustInfo` block (and the
`/MANIFESTUAC:NO` line in `windows\runner\CMakeLists.txt`) if you only want
proxy-only mode without elevation.

Note for `flutter run`: launch it from an **already elevated** terminal.
Otherwise Windows shows a UAC prompt for the child process and the tool
cannot attach the debugger through it. The release exe from
`flutter build windows` prompts once on double-click, as usual.

### 2. Tunnel engine (already bundled)

The tun2socks engine is the native Windows binary from
<https://github.com/heiher/hev-socks5-tunnel/releases>. This project keeps
a copy of **v2.18.0** (`hev-socks5-tunnel.exe`, `wintun.dll`,
`msys-2.0.dll`) in `third_party\hev-socks5-tunnel\bin\`, and the CMake
build copies it next to `fluttewind.exe` automatically for every Debug and
Release build.

To upgrade the engine: download a newer `hev-socks5-tunnel-win64.zip` from
the releases page, extract it, and replace the three files in
`third_party\hev-socks5-tunnel\bin\`, then rebuild. Settings →
"hev-socks5-tunnel.exe path" can also point to any other copy.

If the files are missing (e.g., `third_party` was deleted), full-VPN
connecting reports "hev-socks5-tunnel.exe was not found"; proxy-only mode
still works.

## Differences from the Android app

- No per-app split tunneling (Windows has no equivalent to
  `VpnService.addDisallowedApplication`).
- Speed statistics come from the in-app SOCKS5 proxy counters.
- The exit check uses a plain-HTTP ip-api.com request over a tunnel stream
  instead of the Cloudflare HTTPS trace.
- Exit-check and DNS settings are under the Settings tab, same options as
  Android minus app exclusion.

## Using proxy-only mode

Turn on Settings → "Proxy-only mode": the app then just runs the local proxy
at `127.0.0.1:1080` (configurable) and points apps/browsers at it manually.
No wintun, no native binary needed.

The local port is **mixed-protocol**: it answers SOCKS5 *and* plain HTTP
proxying (`CONNECT` and absolute-URI requests) on the same port.

## Windows system proxy

Turn on Settings → "Set as Windows system proxy" and, while the app is
connected, it writes the Internet Settings registry values
(`ProxyEnable`/`ProxyServer` → `127.0.0.1:<port>`) and broadcasts the change
through wininet, so browsers and every other proxy-aware app use the tunnel
without per-app configuration. The previous values are restored on
Disconnect and when the window closes. If the app is killed abruptly, reset
manually with:

```
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f
```

## Chaining through another proxy

Settings → "Use an upstream proxy" makes the app dial the Fastly edges
through an existing SOCKS5 or HTTP proxy (with optional auth, stored in the
Windows credential vault). Sign-in, Guardian, the server list and DoH
requests chain through it as well, so the whole program works on networks
that require a proxy — except that the *control-plane* half cannot attach
proxy credentials (dart:io limitation); give the edge connection the
credentials and keep them out of reliance for the control plane, or use a
proxy without auth. "Copy from Windows system proxy" fills the fields from
the machine's current proxy setting. In full-VPN mode the proxy host is
added to the bypass route set, so the chain leaves through the physical
gateway instead of looping into wintun.

## Troubleshooting

- **"the tunnel process exited immediately"** — wintun.dll missing next to
  the binary, or the app is not elevated.
- **Connecting works but nothing loads** — check the Logs tab; if the
  upstream dial fails, try another location or turn off a pinned edge.
- **Windows "route add" failures** — some security software blocks route
  manipulation; the app logs a warning and may still work (slower, control
  plane can loop into the tunnel).
