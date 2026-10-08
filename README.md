<div align="center">

# FoxyVPN for Windows

<p align="center">
  <img src="assets/images/foxyvpn_logo.jpg" alt="FoxyVPN logo" width="140"/>
</p>

![Windows](https://img.shields.io/badge/Windows-10%2F11_x64-0078D4?style=for-the-badge\&logo=windows\&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-0288D1?style=for-the-badge\&logo=flutter\&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-0175C2?style=for-the-badge\&logo=dart\&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-212121?style=for-the-badge)

A simple Windows VPN client built with Flutter and Dart.

FoxyVPN uses a Firefox account and Mozilla's VPN infrastructure to provide VPN access on Windows.

**Free • No subscription • Windows 10/11**

</div>

<br>

## 🔎 Features

| Feature                     | Description                                                         |
| --------------------------- | ------------------------------------------------------------------- |
| 🛡 **System-wide VPN**      | Routes Windows traffic through a Wintun adapter and VPN tunnel      |
| 🦊 **Firefox account**      | Sign in with a Firefox account                                      |
| 🌍 **Multiple servers**     | Choose from available VPN locations                                 |
| 🔌 **Proxy-only mode**      | Local SOCKS5/HTTP proxy without VPN adapter or administrator rights |
| 🖥 **Windows system proxy** | Automatically configure the Windows proxy                           |
| 🔗 **Upstream proxy**       | Connect through an existing SOCKS5 or HTTP proxy                    |
| 🔐 **Encrypted DNS**        | DNS-over-HTTPS with fake-IP handling                                |
| 🚪 **Exit verification**    | Checks that the public IP has changed                               |
| 📊 **Live statistics**      | View connection speed and application logs                          |
| 🌗 **Themes**               | Dark, light and system themes                                       |
| 🔤 **Languages**            | English and فارسی with RTL support                                  |
| 🔔 **Update checker**       | Checks for newer GitHub releases                                    |
| 📱 **Compact UI**           | Fixed 360×800 window matching the Android layout                    |

> [!NOTE]
> Per-app split tunneling is currently not available on Windows.

<br>

## 📸 Screenshots

<p align="center">
  <img src="https://github.com/user-attachments/assets/140d3437-81a8-4d9d-bd9c-b8933fc3a85f" width="30%" alt="Home">
  <img src="https://github.com/user-attachments/assets/4d9797df-6338-4e8b-8083-9abb339f0e7e" width="30%" alt="Server">
  <img src="https://github.com/user-attachments/assets/6be6a236-6d5e-4eef-9c88-7c3237495116" width="30%" alt="Settings">
</p>

<br>

## 🧿 How It Works

```text
Windows Apps
     │
     ▼
Wintun Adapter
     │
     ▼
hev-socks5-tunnel
     │
     ▼
Local Proxy
127.0.0.1:21080
     │
     ▼
HTTP/2 + TLS
     │
     ▼
Fastly Edge
     │
     ▼
Internet
```

### Main Components

| File                                | Purpose                                                        |
| ----------------------------------- | -------------------------------------------------------------- |
| `lib/vpn/vpn_controller.dart`       | VPN connection flow, watchdog, server switching and statistics |
| `lib/vpn/route_manager.dart`        | Windows routes and DNS management                              |
| `lib/vpn/local_socks5_server.dart`  | Local SOCKS5 and HTTP proxy                                    |
| `lib/vpn/system_proxy_manager.dart` | Windows system proxy management                                |
| `lib/vpn/h2_upstream_session.dart`  | HTTP/2 connection to the VPN edge                              |
| `lib/data/`                         | Authentication, server data, settings and secure storage       |
| `lib/ui/`                           | Application screens and user interface                         |

<br>

## 🚀 How to Use

1. Create a free Firefox account.
2. Launch `FoxyVPN.exe`.
3. Sign in with your Firefox account.
4. Select a location.
5. Press the power button.

Full-VPN mode requires administrator privileges.

> [!IMPORTANT]
> The free VPN allowance is limited. When the monthly allowance is exhausted, VPN connections will stop until the allowance resets.

<br>

## 🗃 Requirements

* Windows 10 / 11 x64
* Administrator privileges for Full-VPN mode
* Flutter SDK for building
* Visual Studio with **Desktop development with C++**

<br>

## ⚙️ Build

```bash
git clone https://github.com/M-RTZ1/FoxyVPN.git
cd FoxyVPN

flutter pub get
flutter build windows --release
```

Build output:

```text
build\windows\x64\runner\Release\
```

Before committing:

```bash
flutter analyze
flutter test
```

<br>

## 🚀 Publishing a Release

1. Update the version in `pubspec.yaml`.
2. Create a GitHub Release using the same version.
3. Build the application with:

```bash
flutter build windows --release
```

4. ZIP the **entire `Release` folder**.
5. Upload the ZIP to the GitHub Release.

> [!IMPORTANT]
> Do not upload only `FoxyVPN.exe`. The application also requires its DLL files and `data` directory.

<br>

## 🪟 VPN Modes

### Full-VPN Mode

Full-VPN mode:

* Requires administrator privileges
* Creates the Wintun adapter
* Takes over the IPv4 default route
* Configures DNS
* Routes system traffic through the VPN

### Proxy-only Mode

Proxy-only mode runs a local proxy without creating a VPN adapter.

Default address:

```text
127.0.0.1:21080
```

The proxy supports:

* SOCKS5
* HTTP proxy
* HTTP `CONNECT`

No administrator privileges are required.

### Windows System Proxy

FoxyVPN can configure the Windows system proxy automatically.

The previous proxy settings are restored when the VPN disconnects.

<br>

## 🔗 Upstream Proxy

FoxyVPN can connect to the VPN service through an existing:

* SOCKS5 proxy
* HTTP proxy

The upstream proxy can also be copied from the current Windows system proxy settings.

In Full-VPN mode, the upstream proxy is bypassed from the VPN route to prevent routing loops.

<br>

## 🔧 Tunnel Engine

FoxyVPN uses [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) together with Wintun.

The required native files are included in:

```text
third_party\hev-socks5-tunnel\bin\
```

A fresh clone therefore does not require a separate tunnel-engine download.

If the tunnel files are missing, Full-VPN mode will not start, while Proxy-only mode can still be used.

<br>

## 🔧 Troubleshooting

| Problem                             | Possible solution                                                  |
| ----------------------------------- | ------------------------------------------------------------------ |
| Tunnel exits immediately            | Check that `wintun.dll` and the tunnel files are present           |
| Nothing loads after connecting      | Check the **Logs** tab and try another server                      |
| Route errors                        | Check whether another VPN or security software is modifying routes |
| Proxy remains enabled after a crash | Disable the Windows system proxy manually                          |
| Quota error                         | The monthly VPN allowance has been exhausted                       |

To disable the Windows system proxy:

```bat
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings" /v ProxyEnable /t REG_DWORD /d 0 /f
```

<br>

## 📱 Differences from Android

* No per-app split tunneling
* Windows-specific route and DNS management
* Windows system proxy support
* Speed statistics use the local proxy counters
* Compact desktop interface

<br>

## 📝 To-Do

* [x] VPN routing
* [x] DNS management
* [x] SOCKS5/HTTP proxy
* [x] Windows system proxy
* [x] Upstream proxy support
* [x] App icon and logo
* [ ] Installer and auto-update
* [ ] IPv6 support
* [ ] Per-app split tunneling
* [ ] HTTP/3

<br>

## ✍️ Acknowledgements

* [firefox-vpn-client](https://github.com/UjuiUjuMandan/firefox-vpn-client) — Go reference client
* [FoxyVPN](https://github.com/Vauth/FoxyVPN) — Android version
* [hev-socks5-tunnel](https://github.com/heiher/hev-socks5-tunnel) — tunnel engine
* [Wintun](https://www.wintun.net/) — Windows tunnel driver
* [Flutter](https://flutter.dev) — desktop UI framework

<br>

## 🛠 Contributing

Contributions are welcome.

For larger changes, please open an issue before submitting a pull request.

Before submitting a pull request, make sure these commands pass:

```bash
flutter analyze
flutter test
```

<br>

## ⚠️ Disclaimer

FoxyVPN is an unofficial client and is not affiliated with, endorsed by, or supported by Mozilla or Fastly.

Review the source code before using the application with your Firefox account or network traffic.

<br>

## 📄 License

This project is licensed under the MIT License.

See the [LICENSE](LICENSE) file for details.
