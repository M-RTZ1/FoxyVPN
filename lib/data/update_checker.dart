import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/app_logger.dart';
import '../core/app_version.dart';
import '../core/open_in_browser.dart';
import 'control_plane_http.dart';
import 'settings_store.dart';

const String _tag = 'UpdateChecker';

/// Result of the most recent release check.
enum UpdateStatus {
  unknown,
  checking,

  /// Newest published release is the one already running.
  upToDate,

  /// A newer release exists.
  available,

  /// The repository has no published release yet.
  nonePublished,

  /// GitHub could not be reached or answered something unexpected.
  failed,
}

/// A GitHub release, narrowed to what the update prompt needs.
class GithubRelease {
  const GithubRelease({
    required this.tag,
    required this.version,
    required this.pageUrl,
    required this.prerelease,
    this.changelog = '',
    this.assetName,
    this.assetUrl,
    this.publishedAt,
  });

  final String tag;

  /// [tag] without the leading `v` and without `+build`.
  final String version;
  final String pageUrl;
  final bool prerelease;
  final String changelog;
  final String? assetName;

  /// The Windows build attached to the release, when the author uploaded one.
  final String? assetUrl;
  final DateTime? publishedAt;

  /// Where the user actually gets the new version.
  String get downloadUrl => assetUrl ?? pageUrl;
}

/// Checks `github.com/M-RTZ1/FoxyVPN/releases` for a newer build and holds the
/// result for the Home banner and the Settings → About row.
class UpdateChecker extends ChangeNotifier {
  UpdateChecker._();

  static final UpdateChecker instance = UpdateChecker._();

  static const String repoSlug = 'M-RTZ1/FoxyVPN';

  static const String releasesPageUrl = 'https://github.com/$repoSlug/releases';

  static Uri get _latestReleaseApi =>
      Uri.parse('https://api.github.com/repos/$repoSlug/releases/latest');

  /// A release poll is cheap but rate-limited (60/hour per IP for
  /// unauthenticated GitHub), and people relaunch apps often.
  static const Duration checkInterval = Duration(hours: 24);

  UpdateStatus _status = UpdateStatus.unknown;
  UpdateStatus get status => _status;

  GithubRelease? _latest;
  GithubRelease? get latest => _latest;

  String? _error;
  String? get error => _error;

  /// Whether the Home screen should nag. False once the user has dismissed
  /// this exact release; the next version asks again.
  bool get updateAvailable =>
      _status == UpdateStatus.available && _latest != null && !dismissed;

  bool get dismissed =>
      _latest != null &&
      SettingsStore.instance.dismissedUpdateTag == _latest!.tag;

  /// Called on startup: skips the network when a recent check already answered.
  Future<void> checkOnStartup() async {
    final lastCheckAt = SettingsStore.instance.lastUpdateCheckAtMillis;
    if (lastCheckAt == 0) return checkNow();
    final ageMillis = DateTime.now().millisecondsSinceEpoch - lastCheckAt;
    if (ageMillis >= checkInterval.inMilliseconds) await checkNow();
  }

  Future<void> checkNow() async {
    _setStatus(UpdateStatus.checking);
    try {
      final response = await ControlPlaneHttp.send(
        'GET',
        _latestReleaseApi,
        headers: const {'Accept': 'application/vnd.github+json'},
        timeout: const Duration(seconds: 15),
      );

      if (response.statusCode == 404) {
        _markChecked();
        _latest = null;
        _setStatus(UpdateStatus.nonePublished, clearError: true);
        AppLogger.i(_tag, 'the repository has no published release yet');
        return;
      }
      if (!response.isSuccessful) {
        throw StateError('GitHub answered HTTP ${response.statusCode}');
      }

      final release = parseRelease(jsonDecode(response.body));
      if (release == null) {
        throw const FormatException('unexpected /releases/latest payload');
      }
      // Only a usable answer spends the 24h window: a network failure should
      // be retried on the next launch rather than silence the check a day.
      _markChecked();
      _latest = release;
      final isNewer = _isAfterCurrentBuild(release);
      _setStatus(
        isNewer ? UpdateStatus.available : UpdateStatus.upToDate,
        clearError: true,
      );
      AppLogger.i(
        _tag,
        'latest release is ${release.tag} (running ${AppVersion.number}): '
        '${isNewer ? 'an update is available' : 'up to date'}',
      );
    } catch (e) {
      _setStatus(UpdateStatus.failed, error: _describe(e));
      AppLogger.w(_tag, 'the update check failed', e);
    }
  }

  /// Opens the release (its Windows asset when there is one) in the browser.
  Future<void> openDownload() async {
    final release = _latest;
    final url = release?.downloadUrl ?? releasesPageUrl;
    AppLogger.i(_tag, 'opening $url in the browser');
    await openInBrowser(url);
  }

  void dismissLatest() {
    final release = _latest;
    if (release == null) return;
    SettingsStore.instance.dismissedUpdateTag = release.tag;
    AppLogger.i(_tag, 'update notification for ${release.tag} dismissed');
    notifyListeners();
  }

  void _markChecked() {
    SettingsStore.instance.lastUpdateCheckAtMillis =
        DateTime.now().millisecondsSinceEpoch;
  }

  bool _isAfterCurrentBuild(GithubRelease release) =>
      compareVersions(release.version, AppVersion.number) > 0;

  void _setStatus(
    UpdateStatus status, {
    String? error,
    bool clearError = false,
  }) {
    _status = status;
    if (clearError) {
      _error = null;
    } else if (error != null) {
      _error = error;
    }
    notifyListeners();
  }

  static String _describe(Object error) {
    if (error is StateError) return error.message;
    if (error is FormatException) return error.message;
    if (error is TimeoutException) return 'the request timed out';
    return error.toString();
  }

  /// `v1.2.0+3`, `1.2.0`, `v1.2.0-beta1` → `1.2.0` / `1.2.0-beta1`.
  static String versionFromTag(String tag) {
    var version = tag.trim();
    if (version.startsWith('v') || version.startsWith('V')) {
      version = version.substring(1);
    }
    final build = version.indexOf('+');
    if (build > 0) version = version.substring(0, build);
    return version;
  }

  /// Numeric `major.minor.patch` order, with a pre-release ranked below the
  /// stable release it precedes. Returns >0 when [left] is newer.
  static int compareVersions(String left, String right) {
    final a = _splitVersion(left);
    final b = _splitVersion(right);
    for (var i = 0; i < 3; i++) {
      final order = a.numbers[i].compareTo(b.numbers[i]);
      if (order != 0) return order;
    }
    if (a.pre == b.pre) return 0;
    // 1.2.0 beats 1.2.0-rc1; between two pre-releases the label decides.
    if (a.pre == null) return 1;
    if (b.pre == null) return -1;
    return a.pre!.compareTo(b.pre!);
  }

  static ({List<int> numbers, String? pre}) _splitVersion(String version) {
    final normalized = versionFromTag(version);
    final dash = normalized.indexOf('-');
    final core = dash < 0 ? normalized : normalized.substring(0, dash);
    final parts = core.split('.');
    final numbers = [0, 0, 0];
    for (var i = 0; i < 3; i++) {
      numbers[i] = i < parts.length ? (int.tryParse(parts[i]) ?? 0) : 0;
    }
    return (
      numbers: numbers,
      pre: dash < 0 ? null : normalized.substring(dash + 1),
    );
  }

  /// Reads the `/releases/latest` JSON. Null when the payload has no usable
  /// tag, so a malformed reply is treated as a failed check rather than a
  /// version called `null`.
  static GithubRelease? parseRelease(Object? payload) {
    if (payload is! Map) return null;
    final tag = (payload['tag_name'] as String?)?.trim();
    if (tag == null || tag.isEmpty) return null;

    final assets = payload['assets'] is List
        ? (payload['assets'] as List).whereType<Map>().toList()
        : const <Map>[];
    final download = _bestWindowsAsset(assets);

    final page = (payload['html_url'] as String?)?.trim() ?? '';

    return GithubRelease(
      tag: tag,
      version: versionFromTag(tag),
      pageUrl: page.isEmpty ? releasesPageUrl : page,
      prerelease: payload['prerelease'] == true,
      changelog: (payload['body'] as String?)?.trim() ?? '',
      assetName: download?.$1,
      assetUrl: download?.$2,
      publishedAt: DateTime.tryParse(
        (payload['published_at'] as String?) ?? '',
      )?.toLocal(),
    );
  }

  /// An installer beats an archive, an archive beats any other upload.
  static (String, String)? _bestWindowsAsset(Iterable<Map> assets) {
    (String, String)? best;
    var bestScore = 0;
    for (final asset in assets) {
      final name = (asset['name'] as String?)?.trim() ?? '';
      final url = (asset['browser_download_url'] as String?)?.trim() ?? '';
      if (name.isEmpty || url.isEmpty) continue;
      final score = switch (name.toLowerCase()) {
        final n when n.endsWith('.msi') || n.endsWith('.msix') => 3,
        final n when n.endsWith('.exe') => 2,
        final n when n.endsWith('.zip') => 1,
        _ => 0,
      };
      if (score > bestScore) {
        bestScore = score;
        best = (name, url);
      }
    }
    return best;
  }
}
