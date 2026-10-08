import 'package:flutter_test/flutter_test.dart';

import 'package:foxyvpn/core/app_version.dart';

void main() {
  test('the version is read from the bundled pubspec.yaml', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppVersion.load();
    // Falls back to 0.0.0 when the asset is not bundled, which would silently
    // make every release look newer than the running build.
    expect(AppVersion.full, isNot('0.0.0'));
    expect(AppVersion.number, matches(RegExp(r'^\d+\.\d+\.\d+$')));
  });
}
