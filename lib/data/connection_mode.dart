/// The three mutually-exclusive operating modes of the VPN client.
enum ConnectionMode {
  /// Only the local SOCKS5/HTTP proxy server runs.
  /// Applications must be manually configured to use it.
  proxy,

  /// The local SOCKS5/HTTP proxy runs AND the Windows system-wide proxy
  /// setting (WinINet) is configured to point at it, so all WinINet-aware
  /// apps (browsers, etc.) are routed automatically.
  systemProxy,

  /// Full system-wide VPN tunnel: hev-socks5-tunnel creates a Wintun
  /// adapter, all IPv4 traffic is rerouted into it, and DNS is hijacked
  /// through the mapdns engine. Requires administrator privileges.
  tunnel,
}
