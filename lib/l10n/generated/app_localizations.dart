import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_fa.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('fa'),
  ];

  /// No description provided for @navHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get navHome;

  /// No description provided for @navServers.
  ///
  /// In en, this message translates to:
  /// **'Servers'**
  String get navServers;

  /// No description provided for @navSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// No description provided for @navLogs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get navLogs;

  /// No description provided for @actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// No description provided for @actionSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get actionSignOut;

  /// No description provided for @signOutDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out?'**
  String get signOutDialogTitle;

  /// No description provided for @signOutDialogBody.
  ///
  /// In en, this message translates to:
  /// **'The tunnel will be disconnected and your Firefox Account session removed from this device.'**
  String get signOutDialogBody;

  /// No description provided for @statusDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get statusDisconnected;

  /// No description provided for @statusConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get statusConnecting;

  /// No description provided for @statusWaitingForNetwork.
  ///
  /// In en, this message translates to:
  /// **'Waiting for network…'**
  String get statusWaitingForNetwork;

  /// No description provided for @statusReconnecting.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting…'**
  String get statusReconnecting;

  /// No description provided for @statusConnectedVpn.
  ///
  /// In en, this message translates to:
  /// **'Connected • {country}'**
  String statusConnectedVpn(String country);

  /// No description provided for @statusProxyActive.
  ///
  /// In en, this message translates to:
  /// **'Proxy active • {address}'**
  String statusProxyActive(String address);

  /// No description provided for @homeEstablishingTunnel.
  ///
  /// In en, this message translates to:
  /// **'Establishing the tunnel…'**
  String get homeEstablishingTunnel;

  /// No description provided for @homeTrafficUnprotected.
  ///
  /// In en, this message translates to:
  /// **'Your traffic is not protected'**
  String get homeTrafficUnprotected;

  /// No description provided for @statDownload.
  ///
  /// In en, this message translates to:
  /// **'Download'**
  String get statDownload;

  /// No description provided for @statUpload.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get statUpload;

  /// No description provided for @quotaPending.
  ///
  /// In en, this message translates to:
  /// **'Quota information appears once the tunnel connects.'**
  String get quotaPending;

  /// No description provided for @quotaLeftOf.
  ///
  /// In en, this message translates to:
  /// **'{remaining} left of {max}'**
  String quotaLeftOf(String remaining, String max);

  /// No description provided for @quotaLeft.
  ///
  /// In en, this message translates to:
  /// **'{remaining} left'**
  String quotaLeft(String remaining);

  /// No description provided for @autoSelectedLocation.
  ///
  /// In en, this message translates to:
  /// **'Auto-selected location'**
  String get autoSelectedLocation;

  /// No description provided for @exitLocation.
  ///
  /// In en, this message translates to:
  /// **'Exit location: {location}'**
  String exitLocation(String location);

  /// No description provided for @serverCardRecommended.
  ///
  /// In en, this message translates to:
  /// **'Recommended (automatic)'**
  String get serverCardRecommended;

  /// No description provided for @serverCardPickLocation.
  ///
  /// In en, this message translates to:
  /// **'Pick a location on the Servers tab'**
  String get serverCardPickLocation;

  /// No description provided for @loginSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Sign in with your Firefox Account'**
  String get loginSubtitle;

  /// No description provided for @loginTwoFactorSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Enter the verification code sent to your email'**
  String get loginTwoFactorSubtitle;

  /// No description provided for @loginEmailLabel.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get loginEmailLabel;

  /// No description provided for @loginPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get loginPasswordLabel;

  /// No description provided for @loginCodeLabel.
  ///
  /// In en, this message translates to:
  /// **'Verification code'**
  String get loginCodeLabel;

  /// No description provided for @loginEmailInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid email address'**
  String get loginEmailInvalid;

  /// No description provided for @loginPasswordRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter your password'**
  String get loginPasswordRequired;

  /// No description provided for @loginSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get loginSignIn;

  /// No description provided for @loginVerify.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get loginVerify;

  /// No description provided for @loginBackToSignIn.
  ///
  /// In en, this message translates to:
  /// **'Back to sign-in'**
  String get loginBackToSignIn;

  /// No description provided for @serversTitle.
  ///
  /// In en, this message translates to:
  /// **'Locations'**
  String get serversTitle;

  /// No description provided for @serversReload.
  ///
  /// In en, this message translates to:
  /// **'Reload'**
  String get serversReload;

  /// No description provided for @serversRecommended.
  ///
  /// In en, this message translates to:
  /// **'Recommended for you'**
  String get serversRecommended;

  /// No description provided for @serversRecommendedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose automatically from the fastest available country'**
  String get serversRecommendedSubtitle;

  /// No description provided for @serversAutoChosen.
  ///
  /// In en, this message translates to:
  /// **'Location will be chosen automatically'**
  String get serversAutoChosen;

  /// No description provided for @serversLocationSet.
  ///
  /// In en, this message translates to:
  /// **'Location set to {country} ({authority})'**
  String serversLocationSet(String country, String authority);

  /// No description provided for @serversLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load the server list: {error}'**
  String serversLoadFailed(String error);

  /// No description provided for @serversNoneAvailable.
  ///
  /// In en, this message translates to:
  /// **'No locations are available right now.'**
  String get serversNoneAvailable;

  /// No description provided for @serversNoServers.
  ///
  /// In en, this message translates to:
  /// **'No usable servers in this country.'**
  String get serversNoServers;

  /// No description provided for @serversCityCount.
  ///
  /// In en, this message translates to:
  /// **'{count} city(ies)'**
  String serversCityCount(int count);

  /// No description provided for @serversPort.
  ///
  /// In en, this message translates to:
  /// **'port {port}'**
  String serversPort(int port);

  /// No description provided for @serversTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get serversTryAgain;

  /// No description provided for @sectionAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get sectionAppearance;

  /// No description provided for @sectionLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get sectionLanguage;

  /// No description provided for @sectionConnection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get sectionConnection;

  /// No description provided for @sectionLocalProxy.
  ///
  /// In en, this message translates to:
  /// **'Local proxy (SOCKS5 + HTTP)'**
  String get sectionLocalProxy;

  /// No description provided for @sectionUpstreamProxy.
  ///
  /// In en, this message translates to:
  /// **'Chain through an upstream proxy'**
  String get sectionUpstreamProxy;

  /// No description provided for @sectionTunnelEngine.
  ///
  /// In en, this message translates to:
  /// **'Tunnel engine'**
  String get sectionTunnelEngine;

  /// No description provided for @sectionAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get sectionAbout;

  /// No description provided for @themeAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get themeAuto;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get languageSystem;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languagePersian.
  ///
  /// In en, this message translates to:
  /// **'فارسی'**
  String get languagePersian;

  /// No description provided for @exitCheckTitle.
  ///
  /// In en, this message translates to:
  /// **'Exit check'**
  String get exitCheckTitle;

  /// No description provided for @exitCheckSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Verify the exit country after connecting and log a warning on mismatch'**
  String get exitCheckSubtitle;

  /// No description provided for @proxyOnlyTitle.
  ///
  /// In en, this message translates to:
  /// **'Proxy-only mode'**
  String get proxyOnlyTitle;

  /// No description provided for @proxyOnlySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Expose only the local proxy; no wintun adapter, no admin rights needed'**
  String get proxyOnlySubtitle;

  /// No description provided for @systemProxyTitle.
  ///
  /// In en, this message translates to:
  /// **'Set as Windows system proxy'**
  String get systemProxyTitle;

  /// No description provided for @systemProxySubtitle.
  ///
  /// In en, this message translates to:
  /// **'While connected, point Windows (and every app that honours it) at the local HTTP proxy; reverted on disconnect'**
  String get systemProxySubtitle;

  /// No description provided for @dohTitle.
  ///
  /// In en, this message translates to:
  /// **'DNS-over-HTTPS resolver (for edge resolution)'**
  String get dohTitle;

  /// No description provided for @customDnsTitle.
  ///
  /// In en, this message translates to:
  /// **'Custom DNS server for the tunnel'**
  String get customDnsTitle;

  /// No description provided for @customDnsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When on, the TUN interface hands this resolver to apps instead of on-device fake-DNS'**
  String get customDnsSubtitle;

  /// No description provided for @customDnsLabel.
  ///
  /// In en, this message translates to:
  /// **'Custom DNS server (IPv4)'**
  String get customDnsLabel;

  /// No description provided for @customDnsHelper.
  ///
  /// In en, this message translates to:
  /// **'e.g. 1.1.1.1'**
  String get customDnsHelper;

  /// No description provided for @errorInvalidDns.
  ///
  /// In en, this message translates to:
  /// **'Invalid DNS server address'**
  String get errorInvalidDns;

  /// No description provided for @pinnedEdgeLabel.
  ///
  /// In en, this message translates to:
  /// **'Pinned edge address (optional)'**
  String get pinnedEdgeLabel;

  /// No description provided for @pinnedEdgeHelper.
  ///
  /// In en, this message translates to:
  /// **'Force every connection to dial this Fastly edge IP'**
  String get pinnedEdgeHelper;

  /// No description provided for @errorInvalidHostOrIp.
  ///
  /// In en, this message translates to:
  /// **'Invalid hostname or IP address'**
  String get errorInvalidHostOrIp;

  /// No description provided for @bindAddressLabel.
  ///
  /// In en, this message translates to:
  /// **'Bind address'**
  String get bindAddressLabel;

  /// No description provided for @localProxyApplyHint.
  ///
  /// In en, this message translates to:
  /// **'Applies at once in proxy-only mode; in full-VPN mode it takes effect on the next connect'**
  String get localProxyApplyHint;

  /// No description provided for @errorInvalidIp.
  ///
  /// In en, this message translates to:
  /// **'Invalid IP address'**
  String get errorInvalidIp;

  /// No description provided for @portLabel.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get portLabel;

  /// No description provided for @errorInvalidPort.
  ///
  /// In en, this message translates to:
  /// **'Invalid port number'**
  String get errorInvalidPort;

  /// No description provided for @upstreamTitle.
  ///
  /// In en, this message translates to:
  /// **'Use an upstream proxy'**
  String get upstreamTitle;

  /// No description provided for @upstreamSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Route everything (sign-in, Guardian, server list and the edge dials) through a SOCKS5 or HTTP proxy; credentials apply to the edge connection'**
  String get upstreamSubtitle;

  /// No description provided for @proxyTypeLabel.
  ///
  /// In en, this message translates to:
  /// **'Proxy type'**
  String get proxyTypeLabel;

  /// No description provided for @proxyTypeHttp.
  ///
  /// In en, this message translates to:
  /// **'HTTP (CONNECT)'**
  String get proxyTypeHttp;

  /// No description provided for @proxyHostLabel.
  ///
  /// In en, this message translates to:
  /// **'Proxy host'**
  String get proxyHostLabel;

  /// No description provided for @proxyPortLabel.
  ///
  /// In en, this message translates to:
  /// **'Proxy port'**
  String get proxyPortLabel;

  /// No description provided for @copyFromSystemProxy.
  ///
  /// In en, this message translates to:
  /// **'Copy from Windows system proxy'**
  String get copyFromSystemProxy;

  /// No description provided for @noSystemProxyConfigured.
  ///
  /// In en, this message translates to:
  /// **'Windows has no system proxy configured'**
  String get noSystemProxyConfigured;

  /// No description provided for @unparsableSystemProxy.
  ///
  /// In en, this message translates to:
  /// **'Could not understand the Windows proxy setting: {value}'**
  String unparsableSystemProxy(String value);

  /// No description provided for @proxyUsernameLabel.
  ///
  /// In en, this message translates to:
  /// **'Proxy username (optional)'**
  String get proxyUsernameLabel;

  /// No description provided for @proxyPasswordLabel.
  ///
  /// In en, this message translates to:
  /// **'Proxy password (optional)'**
  String get proxyPasswordLabel;

  /// No description provided for @saveCredentials.
  ///
  /// In en, this message translates to:
  /// **'Save credentials'**
  String get saveCredentials;

  /// No description provided for @credentialsSaved.
  ///
  /// In en, this message translates to:
  /// **'Proxy credentials saved'**
  String get credentialsSaved;

  /// No description provided for @tunnelPathLabel.
  ///
  /// In en, this message translates to:
  /// **'hev-socks5-tunnel.exe path'**
  String get tunnelPathLabel;

  /// No description provided for @tunnelPathHelper.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to look next to the app executable (or in bin\\). Required for full-VPN mode; proxy-only mode does not need it.'**
  String get tunnelPathHelper;

  /// No description provided for @aboutBody.
  ///
  /// In en, this message translates to:
  /// **'FoxyVPN for Windows • traffic rides HTTP/2 CONNECT streams through Fastly edges using your Mozilla VPN entitlement (50 GB/month free).\n\nFull-VPN mode creates a wintun adapter and needs the app to run as administrator.'**
  String get aboutBody;

  /// No description provided for @aboutSource.
  ///
  /// In en, this message translates to:
  /// **'Source: github.com/M-RTZ1/FoxyVPN'**
  String get aboutSource;

  /// No description provided for @copySourceUrl.
  ///
  /// In en, this message translates to:
  /// **'Copy the project source URL'**
  String get copySourceUrl;

  /// No description provided for @sourceUrlCopied.
  ///
  /// In en, this message translates to:
  /// **'Source URL copied'**
  String get sourceUrlCopied;

  /// No description provided for @logsTitle.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get logsTitle;

  /// No description provided for @logsShowOldestFirst.
  ///
  /// In en, this message translates to:
  /// **'Show oldest first'**
  String get logsShowOldestFirst;

  /// No description provided for @logsShowNewestFirst.
  ///
  /// In en, this message translates to:
  /// **'Show newest first'**
  String get logsShowNewestFirst;

  /// No description provided for @logsCopyAll.
  ///
  /// In en, this message translates to:
  /// **'Copy all'**
  String get logsCopyAll;

  /// No description provided for @logsExportToFile.
  ///
  /// In en, this message translates to:
  /// **'Export to file'**
  String get logsExportToFile;

  /// No description provided for @logsClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get logsClear;

  /// No description provided for @logsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No log entries yet.'**
  String get logsEmpty;

  /// No description provided for @logsCopiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Logs copied to the clipboard'**
  String get logsCopiedToClipboard;

  /// No description provided for @logsExported.
  ///
  /// In en, this message translates to:
  /// **'Log exported to {path}'**
  String logsExported(String path);

  /// No description provided for @logsExportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed: {error}'**
  String logsExportFailed(String error);

  /// No description provided for @aboutVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String aboutVersion(String version);

  /// No description provided for @updateCheckAction.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get updateCheckAction;

  /// No description provided for @updateChecking.
  ///
  /// In en, this message translates to:
  /// **'Checking GitHub…'**
  String get updateChecking;

  /// No description provided for @updateUpToDate.
  ///
  /// In en, this message translates to:
  /// **'You are on the newest release ({version})'**
  String updateUpToDate(String version);

  /// No description provided for @updateNonePublished.
  ///
  /// In en, this message translates to:
  /// **'No release has been published on GitHub yet'**
  String get updateNonePublished;

  /// No description provided for @updateFailed.
  ///
  /// In en, this message translates to:
  /// **'The update check failed: {error}'**
  String updateFailed(String error);

  /// No description provided for @updateAvailableTitle.
  ///
  /// In en, this message translates to:
  /// **'FoxyVPN {latest} is available'**
  String updateAvailableTitle(String latest);

  /// No description provided for @updateAvailableBody.
  ///
  /// In en, this message translates to:
  /// **'You are running version {current}. Download the new build from its GitHub release.'**
  String updateAvailableBody(String current);

  /// No description provided for @updateActionDownload.
  ///
  /// In en, this message translates to:
  /// **'Download {asset}'**
  String updateActionDownload(String asset);

  /// No description provided for @updateActionOpenRelease.
  ///
  /// In en, this message translates to:
  /// **'Open the release page'**
  String get updateActionOpenRelease;

  /// No description provided for @updateActionNotNow.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get updateActionNotNow;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'fa'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'fa':
      return AppLocalizationsFa();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
