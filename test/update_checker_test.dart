import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:foxyvpn/data/update_checker.dart';

void main() {
  group('version parsing', () {
    test('tag prefix and build metadata are dropped', () {
      expect(UpdateChecker.versionFromTag('v1.2.0+3'), '1.2.0');
      expect(UpdateChecker.versionFromTag('V1.2.0'), '1.2.0');
      expect(UpdateChecker.versionFromTag('  v1.2.0 '), '1.2.0');
      expect(UpdateChecker.versionFromTag('1.2.0-beta1'), '1.2.0-beta1');
    });

    test('release numbering is compared numerically, not lexically', () {
      expect(UpdateChecker.compareVersions('1.0.1', '1.0.0'), greaterThan(0));
      expect(UpdateChecker.compareVersions('1.10.0', '1.9.0'), greaterThan(0));
      expect(UpdateChecker.compareVersions('2.0.0', '1.9.9'), greaterThan(0));
      expect(UpdateChecker.compareVersions('1.1.0', '1.9.0'), lessThan(0));
      expect(UpdateChecker.compareVersions('1.0', '1.0.0'), 0);
    });

    test('a pre-release is older than its stable twin', () {
      expect(
        UpdateChecker.compareVersions('1.0.0', '1.0.0-rc1'),
        greaterThan(0),
      );
      expect(UpdateChecker.compareVersions('1.0.0-rc1', '1.0.0'), lessThan(0));
      expect(UpdateChecker.compareVersions('v1.2.3+456', '1.2.3'), 0);
    });
  });

  group('release payload', () {
    Map<String, Object?> payload({
      String tag = 'v1.1.0',
      String? htmlUrl = 'https://github.com/M-RTZ1/FoxyVPN/releases/tag/v1.1.0',
      List<Map<String, Object?>> assets = const [],
      bool prerelease = false,
    }) => {
      'tag_name': tag,
      'html_url': htmlUrl,
      'prerelease': prerelease,
      'body': 'Fixed the local proxy port.',
      'published_at': '2026-10-01T09:00:00Z',
      'assets': assets,
    };

    test('reads tag, page, changelog and publish date', () {
      final release = UpdateChecker.parseRelease(payload())!;
      expect(release.tag, 'v1.1.0');
      expect(release.version, '1.1.0');
      expect(release.pageUrl, contains('releases/tag/v1.1.0'));
      expect(release.changelog, 'Fixed the local proxy port.');
      expect(release.publishedAt, isNotNull);
      // With no uploaded build the release page is the download target.
      expect(release.downloadUrl, release.pageUrl);
    });

    test('prefers an installer, then an archive, then anything else', () {
      final release = UpdateChecker.parseRelease(
        payload(
          assets: [
            {
              'name': 'notes.txt',
              'browser_download_url': 'https://x/notes.txt',
            },
            {
              'name': 'FoxyVPN-1.1.0-win-x64.zip',
              'browser_download_url': 'https://x/foxy.zip',
            },
            {
              'name': 'FoxyVPN-Setup.exe',
              'browser_download_url': 'https://x/foxy.exe',
            },
          ],
        ),
      )!;
      expect(release.assetName, 'FoxyVPN-Setup.exe');
      expect(release.downloadUrl, 'https://x/foxy.exe');
    });

    test('an archive wins when there is no installer', () {
      final release = UpdateChecker.parseRelease(
        payload(
          assets: [
            {
              'name': 'source.tar.gz',
              'browser_download_url': 'https://x/s.tar.gz',
            },
            {
              'name': 'FoxyVPN-win-x64.zip',
              'browser_download_url': 'https://x/foxy.zip',
            },
          ],
        ),
      )!;
      expect(release.assetName, 'FoxyVPN-win-x64.zip');
    });

    test('assets without a download URL are skipped', () {
      final release = UpdateChecker.parseRelease(
        payload(
          assets: [
            {'name': 'FoxyVPN-Setup.exe'},
            {
              'name': 'FoxyVPN-win-x64.zip',
              'browser_download_url': 'https://x/foxy.zip',
            },
          ],
        ),
      )!;
      expect(release.assetName, 'FoxyVPN-win-x64.zip');
    });

    test('a reply with no usable tag is not a release', () {
      expect(UpdateChecker.parseRelease({'tag_name': '   '}), isNull);
      expect(UpdateChecker.parseRelease({'message': 'Not Found'}), isNull);
      expect(UpdateChecker.parseRelease('rate limited'), isNull);
      expect(UpdateChecker.parseRelease(null), isNull);
    });

    test('a missing page URL falls back to the releases list', () {
      final release = UpdateChecker.parseRelease(payload(htmlUrl: null))!;
      expect(release.pageUrl, UpdateChecker.releasesPageUrl);
    });

    // Captured from api.github.com/repos/M-RTZ1/FoxyVPN/releases/latest: the
    // published tag carries build metadata and no leading `v`.
    test('parses the real GitHub reply', () {
      final fixture = File(
        'test/fixtures/github_release_latest.json',
      ).readAsStringSync();
      final release = UpdateChecker.parseRelease(jsonDecode(fixture))!;
      expect(release.tag, '1.0.0+2');
      expect(release.version, '1.0.0');
      expect(release.prerelease, isFalse);
      expect(release.assetName, 'FoxyVPN.exe');
      expect(release.downloadUrl, endsWith('/FoxyVPN.exe'));
      expect(release.publishedAt, isNotNull);

      // The shipped build matches that tag, so nothing is offered.
      expect(UpdateChecker.compareVersions(release.version, '1.0.0'), 0);
      expect(
        UpdateChecker.compareVersions(release.version, '0.9.9'),
        greaterThan(0),
      );
    });
  });
}
