// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get navHome => 'Home';

  @override
  String get navServers => 'Servers';

  @override
  String get navSettings => 'Settings';

  @override
  String get navLogs => 'Logs';

  @override
  String get actionCancel => 'Cancel';

  @override
  String get elevationDialogTitle => 'Administrator access required';

  @override
  String get elevationDialogBody =>
      'Tunnel mode creates a network adapter and changes system routes and DNS, which Windows allows only with Administrator rights.\n\nFoxyVPN will restart with Administrator access. Proxy and Windows Proxy modes keep running without it.';

  @override
  String get elevationContinue => 'Restart as Administrator';

  @override
  String get elevationDenied =>
      'Administrator access was not granted, so Tunnel mode cannot start. Proxy and Windows Proxy modes still work.';

  @override
  String get elevationFailed =>
      'FoxyVPN could not restart with Administrator access.';

  @override
  String get actionSignOut => 'Sign out';

  @override
  String get signOutDialogTitle => 'Sign out?';

  @override
  String get signOutDialogBody =>
      'The tunnel will be disconnected and your Firefox Account session removed from this device.';

  @override
  String get statusDisconnected => 'Disconnected';

  @override
  String get statusConnecting => 'Connecting…';

  @override
  String get statusWaitingForNetwork => 'Waiting for network…';

  @override
  String get statusReconnecting => 'Reconnecting…';

  @override
  String statusTunnelActive(String country) {
    return 'Tunnel • $country';
  }

  @override
  String statusSystemProxyActive(String address) {
    return 'System proxy • $address';
  }

  @override
  String statusProxyActive(String address) {
    return 'Proxy • $address';
  }

  @override
  String get homeEstablishingTunnel => 'Establishing the connection…';

  @override
  String get homeTrafficUnprotected => 'Your traffic is not protected';

  @override
  String homeLocalProxy(String address) {
    return 'Local proxy at $address';
  }

  @override
  String get statDownload => 'Download';

  @override
  String get statUpload => 'Upload';

  @override
  String get quotaPending =>
      'Quota information appears once the tunnel connects.';

  @override
  String quotaLeftOf(String remaining, String max) {
    return '$remaining left of $max';
  }

  @override
  String quotaLeft(String remaining) {
    return '$remaining left';
  }

  @override
  String get autoSelectedLocation => 'Auto-selected location';

  @override
  String homeSplitTunnelRules(int count) {
    return '$count split-tunnel rule(s) armed';
  }

  @override
  String homeSplitTunnelBypassed(int count) {
    return '$count connection(s) went around the VPN';
  }

  @override
  String get dataUsageTitle => 'Data usage';

  @override
  String get dataUsageSinceStart => 'Since FoxyVPN started';

  @override
  String get dataUsageReset => 'Reset the counters';

  @override
  String get notificationsTitle => 'Connection notifications';

  @override
  String get notificationsSubtitle =>
      'Show a Windows notification when the VPN connects or disconnects';

  @override
  String get minimizeToTrayTitle => 'Minimize to system tray';

  @override
  String get minimizeToTraySubtitle =>
      'Keep the VPN running in the notification area; use its icon to reopen the window or quit';

  @override
  String get trayTooltip => 'FoxyVPN is running';

  @override
  String get trayShow => 'Show FoxyVPN';

  @override
  String get trayQuit => 'Quit FoxyVPN';

  @override
  String get notificationConnectedTitle => 'FoxyVPN connected';

  @override
  String get notificationConnectedBody => 'Your traffic is now protected.';

  @override
  String notificationConnectedBodyLocation(String location) {
    return 'Your traffic is now protected • Exit: $location';
  }

  @override
  String get notificationDisconnectedTitle => 'FoxyVPN disconnected';

  @override
  String get notificationDisconnectedBody =>
      'Your traffic is no longer protected.';

  @override
  String exitLocation(String location) {
    return 'Exit location: $location';
  }

  @override
  String get serverCardRecommended => 'Recommended (automatic)';

  @override
  String get serverCardPickLocation => 'Pick a location on the Servers tab';

  @override
  String get loginSubtitle => 'Sign in with your Firefox Account';

  @override
  String get loginTwoFactorSubtitle =>
      'Enter the verification code sent to your email';

  @override
  String get loginEmailLabel => 'Email';

  @override
  String get loginPasswordLabel => 'Password';

  @override
  String get loginCodeLabel => 'Verification code';

  @override
  String get loginEmailInvalid => 'Enter a valid email address';

  @override
  String get loginPasswordRequired => 'Enter your password';

  @override
  String get loginSignIn => 'Sign in';

  @override
  String get loginVerify => 'Verify';

  @override
  String get loginBackToSignIn => 'Back to sign-in';

  @override
  String get serversTitle => 'Locations';

  @override
  String get serversReload => 'Reload';

  @override
  String get serversRecommended => 'Recommended for you';

  @override
  String get serversRecommendedSubtitle =>
      'Choose automatically from the fastest available country';

  @override
  String get serversAutoChosen => 'Location will be chosen automatically';

  @override
  String serversLocationSet(String country, String authority) {
    return 'Location set to $country ($authority)';
  }

  @override
  String serversLoadFailed(String error) {
    return 'Could not load the server list: $error';
  }

  @override
  String get serversNoneAvailable => 'No locations are available right now.';

  @override
  String get serversBundledSnapshot =>
      'The live server list could not be reached, so the copy bundled with the app is shown. It may be outdated.';

  @override
  String get serversNoServers => 'No usable servers in this country.';

  @override
  String serversCityCount(int count) {
    return '$count city(ies)';
  }

  @override
  String serversPort(int port) {
    return 'port $port';
  }

  @override
  String get serversPinging => 'pinging…';

  @override
  String get serversPingUnavailable => 'ping unavailable';

  @override
  String serversPingResult(int ms) {
    return '$ms ms';
  }

  @override
  String get serversSearchHint => 'Search countries';

  @override
  String serversNoMatch(String query) {
    return 'No country matches “$query”.';
  }

  @override
  String get serversTryAgain => 'Try again';

  @override
  String get sectionAppearance => 'Appearance';

  @override
  String get sectionLanguage => 'Language';

  @override
  String get sectionConnection => 'Connection';

  @override
  String get sectionConnectionMode => 'Connection mode';

  @override
  String get connectionModeProxy => 'Proxy';

  @override
  String get connectionModeSystemProxy => 'System proxy';

  @override
  String get connectionModeTunnel => 'Tunnel';

  @override
  String get connectionModeProxyDesc =>
      'Only apps manually configured to use the local proxy (127.0.0.1:21080) are routed through the VPN.';

  @override
  String get connectionModeSystemProxyDesc =>
      'Windows system proxy is set automatically so most apps (browsers, etc.) route through the VPN without manual configuration.';

  @override
  String get connectionModeTunnelDesc =>
      'Full system-wide VPN: all traffic is routed through the tunnel via a Wintun adapter. Requires running as Administrator.';

  @override
  String get connectionModeProxyOnlyNote =>
      'Tunnel and system proxy modes are Windows-only for now; on this platform FoxyVPN runs the local proxy.';

  @override
  String get sectionLocalProxy => 'Local proxy (SOCKS5 + HTTP)';

  @override
  String get sectionUpstreamProxy => 'Upstream proxy';

  @override
  String get sectionTunnelEngine => 'Tunnel engine';

  @override
  String get sectionAbout => 'About';

  @override
  String get sectionGeneral => 'General';

  @override
  String get sectionDns => 'DNS';

  @override
  String get sectionAdvanced => 'Advanced';

  @override
  String get advancedSubtitle =>
      'Local proxy, pinned edge and the tunnel engine';

  @override
  String get themeAuto => 'Auto';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get languageSystem => 'Auto';

  @override
  String get languageEnglish => 'English';

  @override
  String get languagePersian => 'فارسی';

  @override
  String get exitCheckTitle => 'Connection test after connecting';

  @override
  String get exitCheckSubtitle =>
      'Fetch a small HTTPS page through the VPN, show the exit country, and log a warning on mismatch';

  @override
  String get connectionTestTitle => 'Connection test';

  @override
  String get connectionTestIdle =>
      'Check that traffic actually reaches the internet through the VPN.';

  @override
  String get connectionTestRunning => 'Testing through the VPN…';

  @override
  String connectionTestPassed(int ms) {
    return 'Passed in $ms ms';
  }

  @override
  String connectionTestPassedWithCountry(int ms, String country) {
    return 'Passed in $ms ms • Exit: $country';
  }

  @override
  String connectionTestFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get connectionTestRunAgain => 'Run again';

  @override
  String customDnsFallbackNotice(String server) {
    return 'Custom DNS $server did not answer through the VPN, so the built-in resolver is active for this connection.';
  }

  @override
  String get noticeDismiss => 'Dismiss';

  @override
  String get dohTitle => 'DNS-over-HTTPS resolver (for edge resolution)';

  @override
  String get customDnsTitle => 'Custom DNS server for the tunnel';

  @override
  String get customDnsSubtitle =>
      'Hand this resolver to apps instead of the built-in fake-DNS. It must answer DNS over TCP through the tunnel; FoxyVPN falls back automatically when it cannot';

  @override
  String get customDnsLabel => 'Custom DNS server (IPv4)';

  @override
  String get customDnsHelper => 'e.g. 1.1.1.1';

  @override
  String get errorInvalidDns => 'Invalid DNS server address';

  @override
  String get pinnedEdgeLabel => 'Pinned edge address (optional)';

  @override
  String get pinnedEdgeHelper =>
      'Force every connection to dial this Fastly edge IP';

  @override
  String get errorInvalidHostOrIp => 'Invalid hostname or IP address';

  @override
  String get bindAddressLabel => 'Bind address';

  @override
  String get localProxyApplyHint =>
      'Applies at once in proxy-only mode; in full-VPN mode it takes effect on the next connect';

  @override
  String get errorInvalidIp => 'Invalid IP address';

  @override
  String get portLabel => 'Port';

  @override
  String get errorInvalidPort => 'Invalid port number';

  @override
  String get sectionSplitTunnel => 'Split tunneling';

  @override
  String get splitTunnelTitle => 'Split tunneling by destination';

  @override
  String get splitTunnelSubtitle =>
      'Send chosen domains and address ranges around the VPN. Per-app rules are not possible: the tunnel cannot see which process opened a connection.';

  @override
  String get splitTunnelDefaultTitle => 'Traffic that matches no rule';

  @override
  String get splitTunnelActionTunnel => 'Via VPN';

  @override
  String get splitTunnelActionDirect => 'Bypass VPN';

  @override
  String get splitTunnelActionLabel => 'Action for the rule you add next';

  @override
  String get splitTunnelPatternLabel => 'Domain or address';

  @override
  String get splitTunnelPatternHelper =>
      'e.g. .ir, example.com, 203.0.113.7 or 192.168.0.0/16';

  @override
  String get splitTunnelAddRule => 'Add rule';

  @override
  String get splitTunnelInvalidPattern => 'Not a usable domain or address';

  @override
  String get splitTunnelNoRules =>
      'No rules yet. Add a TLD such as .ir, a hostname, or an IPv4 range.';

  @override
  String get splitTunnelDeleteRule => 'Remove this rule';

  @override
  String get splitTunnelApplyHint =>
      'Rules apply to new connections. IPv4 only: the tunnel carries no IPv6 traffic, so IPv6 already leaves the VPN.';

  @override
  String get upstreamTitle => 'Use an upstream proxy';

  @override
  String get upstreamSubtitle =>
      'Route everything (sign-in, Guardian, server list and the edge dials) through a SOCKS5 or HTTP proxy; credentials apply to the edge connection';

  @override
  String get proxyTypeLabel => 'Proxy type';

  @override
  String get proxyTypeHttp => 'HTTP (CONNECT)';

  @override
  String get proxyHostLabel => 'Proxy host';

  @override
  String get proxyPortLabel => 'Proxy port';

  @override
  String get copyFromSystemProxy => 'Copy from Windows system proxy';

  @override
  String get noSystemProxyConfigured =>
      'Windows has no system proxy configured';

  @override
  String unparsableSystemProxy(String value) {
    return 'Could not understand the Windows proxy setting: $value';
  }

  @override
  String get proxyUsernameLabel => 'Proxy username (optional)';

  @override
  String get proxyPasswordLabel => 'Proxy password (optional)';

  @override
  String get saveCredentials => 'Save credentials';

  @override
  String get credentialsSaved => 'Proxy credentials saved';

  @override
  String get tunnelPathLabel => 'hev-socks5-tunnel.exe path';

  @override
  String get tunnelPathHelper =>
      'Leave empty to look next to the app executable (or in bin\\). Required for full-VPN mode; proxy-only mode does not need it.';

  @override
  String get aboutBody =>
      'FoxyVPN for Windows • traffic rides HTTP/2 CONNECT streams through Fastly edges using your Mozilla VPN entitlement (50 GB/month free).\n\nFull-VPN mode creates a wintun adapter and needs the app to run as administrator.';

  @override
  String get aboutSource => 'Source: github.com/M-RTZ1/FoxyVPN';

  @override
  String get copySourceUrl => 'Copy the project source URL';

  @override
  String get sourceUrlCopied => 'Source URL copied';

  @override
  String get logsTitle => 'Logs';

  @override
  String get logsShowOldestFirst => 'Show oldest first';

  @override
  String get logsShowNewestFirst => 'Show newest first';

  @override
  String get logsCopyAll => 'Copy all';

  @override
  String get logsExportToFile => 'Export to file';

  @override
  String get logsClear => 'Clear';

  @override
  String get logsEmpty => 'No log entries yet.';

  @override
  String get logsCopiedToClipboard => 'Logs copied to the clipboard';

  @override
  String logsExported(String path) {
    return 'Log exported to $path';
  }

  @override
  String logsExportFailed(String error) {
    return 'Export failed: $error';
  }

  @override
  String aboutVersion(String version) {
    return 'Version $version';
  }

  @override
  String get updateCheckAction => 'Check for updates';

  @override
  String get updateChecking => 'Checking GitHub…';

  @override
  String updateUpToDate(String version) {
    return 'You are on the newest release ($version)';
  }

  @override
  String get updateNonePublished =>
      'No release has been published on GitHub yet';

  @override
  String updateFailed(String error) {
    return 'The update check failed: $error';
  }

  @override
  String updateAvailableTitle(String latest) {
    return 'FoxyVPN $latest is available';
  }

  @override
  String updateAvailableBody(String current) {
    return 'You are running version $current. Download the new build from its GitHub release.';
  }

  @override
  String updateActionDownload(String asset) {
    return 'Download $asset';
  }

  @override
  String get updateActionOpenRelease => 'Open the release page';

  @override
  String get updateActionNotNow => 'Not now';
}
