import 'dart:ffi';
import 'dart:io';

import '../core/app_logger.dart';

const String _tag = 'SystemProxy';

const String _registryKey =
    r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

const int _internetOptionSettingsChanged = 39;
const int _internetOptionRefresh = 37;

typedef _InternetSetOptionNative =
    Int32 Function(
      IntPtr handle,
      Uint32 option,
      IntPtr buffered,
      Uint32 length,
    );
typedef _InternetSetOptionDart =
    int Function(int handle, int option, int buffered, int length);

/// Reads and writes the Windows *system* proxy (the Internet Settings
/// registry values every WinINET/WinHTTP app and browser honours), then
/// broadcasts the change through wininet so running apps pick it up without
/// a restart. The proxy server value is applied while the local frontend is
/// up and the previous state is restored on disconnect.
class SystemProxyManager {
  SystemProxyManager._();

  static final SystemProxyManager instance = SystemProxyManager._();

  bool _applied = false;
  String? _savedEnable;
  String? _savedServer;

  Future<void> apply(String server) async {
    if (_applied) return;
    _savedEnable = await _query('ProxyEnable');
    _savedServer = await _query('ProxyServer');
    await _setValue('ProxyServer', 'REG_SZ', server);
    await _setValue('ProxyEnable', 'REG_DWORD', '1');
    _notify();
    _applied = true;
    AppLogger.i(_tag, 'Windows system proxy enabled -> $server');
  }

  /// Repoints an already-applied system proxy at a new address (the local
  /// frontend rebound to another port). The saved pre-connect state stays as
  /// it is, so [restore] still puts back what the user originally had.
  Future<void> updateServer(String server) async {
    if (!_applied) return apply(server);
    await _setValue('ProxyServer', 'REG_SZ', server);
    _notify();
    AppLogger.i(_tag, 'Windows system proxy moved -> $server');
  }

  Future<void> restore() async {
    if (!_applied) return;
    _applied = false;
    await _restoreValue('ProxyEnable', _savedEnable, type: 'REG_DWORD');
    await _restoreValue('ProxyServer', _savedServer);
    _notify();
    AppLogger.i(_tag, 'Windows system proxy restored to its previous state');
  }

  /// The proxy currently configured in Windows, for the "detect" button in
  /// Settings (and to show what will be restored).
  static Future<({bool enabled, String server})> readCurrent() async {
    final enable = await _query('ProxyEnable');
    final server = await _query('ProxyServer');
    return (
      enabled: enable != null && enable.contains('0x1'),
      server: server ?? '',
    );
  }

  /// Parses a ProxyServer registry value ("host:port", optionally with
  /// per-scheme entries like "http=1.2.3.4:80;https=1.2.3.4:80") into a
  /// dial target.
  static (String, int)? parseServerValue(String value) {
    var candidate = value.trim();
    if (candidate.isEmpty) return null;
    String? chosen;
    for (final segment in candidate.split(';')) {
      final eq = segment.indexOf('=');
      if (eq < 0) {
        chosen ??= segment.trim();
        continue;
      }
      final scheme = segment.substring(0, eq).trim().toLowerCase();
      if (scheme == 'https') {
        chosen = segment.substring(eq + 1).trim();
        break;
      }
      if (scheme == 'http' || scheme == 'socks') {
        chosen ??= segment.substring(eq + 1).trim();
      }
    }
    candidate = chosen ?? candidate;
    candidate = candidate.replaceFirst(RegExp(r'^https?://'), '');
    final colon = candidate.lastIndexOf(':');
    if (colon <= 0) return null;
    final port = int.tryParse(candidate.substring(colon + 1));
    if (port == null) return null;
    return (candidate.substring(0, colon), port);
  }

  static Future<void> _restoreValue(
    String name,
    String? saved, {
    String type = 'REG_SZ',
  }) async {
    if (saved == null) {
      try {
        await Process.run('reg', [
          'delete',
          _registryKey,
          '/v',
          name,
          '/f',
        ], runInShell: true);
      } catch (e) {
        AppLogger.w(_tag, 'could not remove $name', e);
      }
      return;
    }
    await _setValue(name, type, saved);
  }

  static Future<String?> _query(String name) async {
    try {
      final result = await Process.run('reg', [
        'query',
        _registryKey,
        '/v',
        name,
      ], runInShell: true);
      if (result.exitCode != 0) return null;
      for (final rawLine in (result.stdout as String).split('\n')) {
        final line = rawLine.trim();
        if (line.isEmpty || !line.startsWith(name)) continue;
        final columns = line.split(RegExp(r'\s{2,}'));
        if (columns.length >= 3) {
          return columns.sublist(2).join(' ').trim();
        }
      }
      return null;
    } catch (e) {
      AppLogger.w(_tag, 'could not read $name from the registry', e);
      return null;
    }
  }

  static Future<void> _setValue(String name, String type, String data) async {
    try {
      final result = await Process.run('reg', [
        'add',
        _registryKey,
        '/v',
        name,
        '/t',
        type,
        '/d',
        data,
        '/f',
      ], runInShell: true);
      if (result.exitCode != 0) {
        AppLogger.w(
          _tag,
          'reg add $name failed: ${(result.stderr as String).trim()}',
        );
      }
    } catch (e) {
      AppLogger.w(_tag, 'could not write $name to the registry', e);
    }
  }

  static void _notify() {
    try {
      final wininet = DynamicLibrary.open('wininet.dll');
      final setOption = wininet
          .lookupFunction<_InternetSetOptionNative, _InternetSetOptionDart>(
            'InternetSetOptionW',
          );
      setOption(0, _internetOptionSettingsChanged, 0, 0);
      setOption(0, _internetOptionRefresh, 0, 0);
    } catch (e) {
      AppLogger.w(
        _tag,
        'the registry was updated but running apps were not notified; they '
        'will pick the change up when restarted',
        e,
      );
    }
  }

  /// Test seam: performs the wininet broadcast directly (no registry writes)
  /// and reports whether the FFI lookup and both calls succeeded.
  static bool testNotify() {
    try {
      final wininet = DynamicLibrary.open('wininet.dll');
      final setOption = wininet
          .lookupFunction<_InternetSetOptionNative, _InternetSetOptionDart>(
            'InternetSetOptionW',
          );
      final a = setOption(0, _internetOptionSettingsChanged, 0, 0);
      final b = setOption(0, _internetOptionRefresh, 0, 0);
      return a == 1 && b == 1;
    } catch (_) {
      return false;
    }
  }
}
