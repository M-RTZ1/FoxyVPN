// Writes tool/package_config_stub.json: the project's package config with the
// `flutter` package redirected to tool/stub_flutter so the pure-Dart VPN
// libraries compile on a plain Dart VM (no dart:ui).
import 'dart:convert';
import 'dart:io';

void main() {
  final projectRoot = Directory.current;
  final source = File('${projectRoot.path}/.dart_tool/package_config.json');
  if (!source.existsSync()) {
    stderr.writeln('Missing .dart_tool/package_config.json — run `flutter pub get`.');
    exit(1);
  }
  final config = jsonDecode(source.readAsStringSync()) as Map<String, dynamic>;
  final packages = (config['packages'] as List).cast<Map<String, dynamic>>();

  final stubUri = Uri.directory('${projectRoot.path}/tool/stub_flutter')
      .toString();
  var replaced = false;
  for (final pkg in packages) {
    if (pkg['name'] == 'flutter') {
      pkg['rootUri'] = stubUri;
      pkg['packageUri'] = 'lib/';
      pkg['languageVersion'] = '3.0';
      replaced = true;
    }
  }
  if (!replaced) {
    packages.add({
      'name': 'flutter',
      'rootUri': stubUri,
      'packageUri': 'lib/',
      'languageVersion': '3.0',
    });
  }

  File('${projectRoot.path}/tool/package_config_stub.json')
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(config));
  stdout.writeln('Wrote tool/package_config_stub.json (flutter -> stub).');
}
