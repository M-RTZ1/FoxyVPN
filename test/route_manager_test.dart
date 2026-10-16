import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/vpn/hev_socks5_tunnel.dart';
import 'package:foxyvpn/vpn/route_manager.dart';

const _gateway = '192.168.1.1';
const _physicalIndex = 7;
const _tunIndex = 42;
const _mapdns = HevSocks5Tunnel.mapdnsAddress;

typedef _CallMatcher = bool Function(_Call call);

class _Call {
  _Call(this.executable, List<String> arguments)
    : arguments = List.of(arguments);

  final String executable;
  final List<String> arguments;

  bool get isRoute => executable == 'route.exe';
  String get script => isRoute ? '' : arguments.last;
  bool route(String operation, String destination, String mask) =>
      isRoute &&
      arguments[0] == operation &&
      arguments[1] == destination &&
      arguments[3] == mask;
  bool dnsApply(int index) =>
      script.contains('Set-DnsClientServerAddress -InterfaceIndex $index ') &&
      script.contains("-ServerAddresses '$_mapdns'");
  bool dnsRestore(int index) =>
      script.contains('Set-DnsClientServerAddress -InterfaceIndex $index ') &&
      !dnsApply(index);
}

class _Failure {
  _Failure(this.matches, {this.throwProcessException = false});

  final _CallMatcher matches;
  final bool throwProcessException;
}

/// This fake has no fallback to Process.run or InternetAddress.lookup.
class _Windows {
  String defaults = '$_gateway;$_physicalIndex;10;20';
  String tunnel = '$_tunIndex';
  String dnsSnapshot =
      '$_physicalIndex;static;192.168.1.53,192.168.1.54\n'
      '8;dhcp;192.168.2.1\n'
      '$_tunIndex;dhcp;';
  final calls = <_Call>[];
  final lookups = <String>[];
  final answers = <String, List<InternetAddress>>{};
  final routes = <String>{};
  final dns = <int, String>{
    _physicalIndex: '192.168.1.53,192.168.1.54',
    8: 'dhcp',
    _tunIndex: 'dhcp',
  };
  final failures = <_Failure>[];

  RouteManager manager() => RouteManager(
    processRun: run,
    lookup: lookup,
    tunnelWaitTimeout: Duration.zero,
    tunnelPollInterval: Duration.zero,
  );

  void failNext(_CallMatcher matches, {bool throwProcessException = false}) {
    failures.add(
      _Failure(matches, throwProcessException: throwProcessException),
    );
  }

  Future<List<InternetAddress>> lookup(String host) async {
    lookups.add(host);
    return answers[host] ?? [];
  }

  static String routeKey(List<String> args) =>
      '${args[1]}|${args[3]}|${args[4]}|${args.last}';

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    final call = _Call(executable, arguments);
    calls.add(call);
    expect(executable, anyOf('route.exe', 'powershell.exe'));
    if (!call.isRoute) {
      expect(arguments.take(3), ['-NoProfile', '-NonInteractive', '-Command']);
      expect(call.script, startsWith("\$ErrorActionPreference = 'Stop'; "));
      expect(call.script, isNot(contains('SilentlyContinue')));
    }
    final failureIndex = failures.indexWhere(
      (failure) => failure.matches(call),
    );
    if (failureIndex != -1) {
      final failure = failures.removeAt(failureIndex);
      // Simulate a DNS cmdlet that mutates the target before reporting failure.
      if (call.script.contains('Set-DnsClientServerAddress') &&
          call.script.contains("-ServerAddresses '$_mapdns'")) {
        final index = int.parse(
          RegExp(r'-InterfaceIndex (\d+)').firstMatch(call.script)!.group(1)!,
        );
        dns[index] = _mapdns;
      }
      if (failure.throwProcessException) {
        throw ProcessException(executable, arguments, 'mock spawn failure');
      }
      return ProcessResult(1, 1, '', 'mock command failure');
    }
    if (call.isRoute) {
      expect(arguments[2], 'mask');
      expect(arguments[arguments.length - 2], 'if');
      final key = routeKey(arguments);
      if (arguments[0] == 'add') {
        if (!routes.add(key)) {
          return ProcessResult(1, 1, '', 'route already exists');
        }
      } else if (arguments[0] == 'delete') {
        if (!routes.remove(key)) {
          return ProcessResult(1, 1, '', 'route does not exist');
        }
      } else {
        throw StateError('Unexpected mocked route command: $arguments');
      }
      return ProcessResult(1, 0, '', '');
    }
    final script = call.script;
    if (script.contains('Get-NetRoute')) {
      return ProcessResult(1, 0, defaults, '');
    }
    if (script.contains('Get-DnsClientServerAddress')) {
      return ProcessResult(1, 0, dnsSnapshot, '');
    }
    if (script.contains('Get-NetIPAddress')) {
      return ProcessResult(1, 0, tunnel, '');
    }
    if (script.contains('Set-DnsClientServerAddress')) {
      final index = int.parse(
        RegExp(r'-InterfaceIndex (\d+)').firstMatch(script)!.group(1)!,
      );
      if (script.contains('-ResetServerAddresses')) {
        dns[index] = 'dhcp';
      } else {
        final serverText = script.split('-ServerAddresses ').last;
        dns[index] = RegExp(
          r"'([^']+)'",
        ).allMatches(serverText).map((match) => match.group(1)!).join(',');
      }
      return ProcessResult(1, 0, '', '');
    }
    if (script.endsWith('Clear-DnsClientCache')) {
      return ProcessResult(1, 0, '', '');
    }
    throw StateError('Unexpected mocked PowerShell command: $script');
  }

  List<_Call> get mutations => calls
      .where(
        (call) =>
            call.isRoute ||
            call.script.contains('Set-DnsClientServerAddress') ||
            call.script.endsWith('Clear-DnsClientCache'),
      )
      .toList();
  List<_Call> get splitAdds => calls
      .where(
        (call) =>
            call.isRoute &&
            call.arguments[0] == 'add' &&
            call.arguments[3] == '128.0.0.0',
      )
      .toList();
  List<_Call> get splitDeletes => calls
      .where(
        (call) =>
            call.isRoute &&
            call.arguments[0] == 'delete' &&
            call.arguments[3] == '128.0.0.0',
      )
      .toList();
}

void main() {
  group('physical bypass enable', () {
    for (final snapshot in [
      '',
      '0.0.0.0;7;0;0',
      '${HevSocks5Tunnel.tunAddress};42;0;0',
      '192.168.1.1;0;0;0',
      '127.0.0.1;7;0;0',
      '255.255.255.255;7;0;0',
    ]) {
      test('missing usable gateway ($snapshot) changes nothing', () async {
        final windows = _Windows()..defaults = snapshot;
        final manager = windows.manager();
        await expectLater(manager.enable(), throwsStateError);
        expect(manager.isActive, isFalse);
        expect(windows.mutations, isEmpty);
        expect(windows.lookups, isEmpty);
        await manager.disable();
        expect(windows.mutations, isEmpty);
      });
    }

    test('selects connected IPv4 default by combined metrics', () async {
      final windows = _Windows()
        ..defaults =
            '0.0.0.0;2;0;0\n'
            '${HevSocks5Tunnel.tunAddress};42;0;0\n'
            '192.168.3.1;9;1;90\n'
            '$_gateway;$_physicalIndex;10;20';
      final manager = windows.manager();
      await manager.enable();
      final script = windows.calls.first.script;
      expect(script, contains('Get-NetIPInterface -AddressFamily IPv4'));
      expect(script, contains("ConnectionState -eq 'Connected'"));
      expect(script, contains('Get-NetIPAddress -AddressFamily IPv4'));
      expect(script, contains(r'InterfaceIndex -notin $tunIndices'));
      expect(script, contains("NextHop -ne '0.0.0.0'"));
      expect(
        script,
        contains(r'[int]$_.RouteMetric + [int]$_.InterfaceMetric'),
      );
      for (final call in windows.calls.where((call) => call.isRoute)) {
        expect(call.arguments[4], _gateway);
        expect(call.arguments.last, '$_physicalIndex');
      }
      await manager.disable();
    });

    test(
      'query exit failure throws instead of accepting empty stdout',
      () async {
        final windows = _Windows()
          ..failNext((call) => call.script.contains('Get-NetRoute'));
        final manager = windows.manager();
        await expectLater(manager.enable(), throwsStateError);
        expect(manager.isActive, isFalse);
        expect(windows.mutations, isEmpty);
      },
    );

    test('partial bypass add failure rolls back exact owned routes', () async {
      final windows = _Windows()
        ..failNext((call) => call.route('add', '1.0.0.1', '255.255.255.255'));
      final manager = windows.manager();
      await expectLater(manager.enable(), throwsStateError);
      expect(manager.isActive, isFalse);
      expect(windows.routes, isEmpty);
      final deletes = windows.calls
          .where((call) => call.isRoute && call.arguments[0] == 'delete')
          .toList();
      expect(deletes, hasLength(1));
      expect(deletes.single.arguments, [
        'delete',
        '1.1.1.1',
        'mask',
        '255.255.255.255',
        _gateway,
        'if',
        '$_physicalIndex',
      ]);
    });
  });

  group('split route takeover and DNS', () {
    test(
      'preserves physical default throughout takeover and teardown',
      () async {
        final windows = _Windows();
        const physicalDefault = '0.0.0.0|0.0.0.0|$_gateway|$_physicalIndex';
        windows.routes.add(physicalDefault);
        final manager = windows.manager();
        await manager.enable();
        expect(windows.splitAdds, isEmpty);
        await manager.takeoverRoutes();
        expect(manager.takeoverActive, isTrue);
        expect(windows.splitAdds.map((call) => call.arguments), [
          [
            'add',
            '0.0.0.0',
            'mask',
            '128.0.0.0',
            '0.0.0.0',
            'metric',
            '1',
            'if',
            '$_tunIndex',
          ],
          [
            'add',
            '128.0.0.0',
            'mask',
            '128.0.0.0',
            '0.0.0.0',
            'metric',
            '1',
            'if',
            '$_tunIndex',
          ],
        ]);
        expect(windows.routes, contains(physicalDefault));
        await manager.disable();
        expect(windows.routes, {physicalDefault});
        expect(manager.isActive, isFalse);
        expect(manager.takeoverActive, isFalse);
        expect(
          windows.calls.where(
            (call) => call.isRoute && call.arguments[3] == '0.0.0.0',
          ),
          isEmpty,
        );
      },
    );

    test(
      'second split route failure rolls back the first immediately',
      () async {
        final windows = _Windows()
          ..failNext((call) => call.route('add', '128.0.0.0', '128.0.0.0'));
        final manager = windows.manager();
        await manager.enable();
        final bypasses = Set<String>.of(windows.routes);
        await expectLater(manager.takeoverRoutes(), throwsStateError);
        expect(manager.takeoverActive, isFalse);
        expect(windows.routes, bypasses);
        expect(windows.splitDeletes, hasLength(1));
        expect(windows.splitDeletes.single.arguments, [
          'delete',
          '0.0.0.0',
          'mask',
          '128.0.0.0',
          '0.0.0.0',
          'if',
          '$_tunIndex',
        ]);
        expect(
          windows.calls.where(
            (call) => call.script.contains('Set-DnsClientServerAddress'),
          ),
          isEmpty,
        );
        await manager.disable();
      },
    );

    test(
      'DNS mutation failure restores even the failed target and split routes',
      () async {
        final windows = _Windows()..failNext((call) => call.dnsApply(8));
        final manager = windows.manager();
        await manager.enable();
        final bypasses = Set<String>.of(windows.routes);
        await expectLater(manager.takeoverRoutes(), throwsStateError);
        expect(manager.takeoverActive, isFalse);
        expect(windows.routes, bypasses);
        expect(windows.dns, {
          _physicalIndex: '192.168.1.53,192.168.1.54',
          8: 'dhcp',
          _tunIndex: 'dhcp',
        });
        expect(windows.calls.where((call) => call.dnsRestore(8)), hasLength(1));
        expect(
          windows.calls.where((call) => call.dnsApply(_tunIndex)),
          isEmpty,
        );
        expect(windows.calls.last.script, endsWith('Clear-DnsClientCache'));
        await manager.disable();
      },
    );

    test('tunnel DNS mutation failure also resets the tunnel', () async {
      final windows = _Windows()..failNext((call) => call.dnsApply(_tunIndex));
      final manager = windows.manager();
      await manager.enable();
      await expectLater(manager.takeoverRoutes(), throwsStateError);
      expect(windows.dns[_tunIndex], 'dhcp');
      expect(
        windows.calls.where((call) => call.dnsRestore(_tunIndex)),
        hasLength(1),
      );
      expect(windows.splitDeletes, hasLength(2));
      expect(manager.takeoverActive, isFalse);
      await manager.disable();
    });

    test(
      'snapshots ServerAddresses and NameServer; restores static and DHCP DNS',
      () async {
        final windows = _Windows();
        final manager = windows.manager();
        await manager.enable();
        await manager.takeoverRoutes();
        final snapshot = windows.calls
            .singleWhere(
              (call) => call.script.contains('Get-DnsClientServerAddress'),
            )
            .script;
        expect(snapshot, contains(r'$dns.ServerAddresses'));
        expect(snapshot, isNot(contains('DnsServerAddress')));
        expect(snapshot, contains("Properties['NameServer']"));
        expect(snapshot, contains(r'\Services\Tcpip\Parameters\Interfaces\'));
        expect(snapshot, contains("ConnectionState -eq 'Connected'"));
        expect(snapshot, contains('Get-NetIPInterface -AddressFamily IPv4'));
        expect(
          snapshot,
          contains(
            r'Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4',
          ),
        );
        expect(snapshot, contains('Select-Object -Unique'));
        expect(
          windows.calls.where((call) => call.dnsApply(_physicalIndex)),
          hasLength(1),
        );
        expect(windows.calls.where((call) => call.dnsApply(8)), hasLength(1));
        expect(
          windows.calls.where((call) => call.dnsApply(_tunIndex)),
          hasLength(1),
        );
        expect(windows.dns.keys.toSet(), {_physicalIndex, 8, _tunIndex});
        expect(windows.dns.values, everyElement(_mapdns));
        expect(windows.calls.last.script, endsWith('Clear-DnsClientCache'));

        final releaseStart = windows.calls.length;
        await manager.releaseTunnel();
        final released = windows.calls.skip(releaseStart).toList();
        expect(
          released.first.script,
          contains('-InterfaceIndex $_tunIndex -ResetServerAddresses'),
        );
        expect(
          windows.calls
              .singleWhere((call) => call.dnsRestore(_physicalIndex))
              .script,
          contains("-ServerAddresses @('192.168.1.53','192.168.1.54')"),
        );
        expect(
          windows.calls.singleWhere((call) => call.dnsRestore(8)).script,
          contains('-ResetServerAddresses'),
        );
        expect(released.last.script, endsWith('Clear-DnsClientCache'));
        expect(windows.dns.values, isNot(contains(_mapdns)));
        expect(manager.takeoverActive, isFalse);
        final count = windows.calls.length;
        await manager.releaseTunnel();
        expect(windows.calls, hasLength(count));
        await manager.disable();
      },
    );

    test('static tunnel DNS is restored instead of reset', () async {
      final windows = _Windows()
        ..dnsSnapshot = '7;dhcp;192.168.1.1\n42;static;10.8.0.1'
        ..dns[_tunIndex] = '10.8.0.1';
      final manager = windows.manager();
      await manager.enable();
      await manager.takeoverRoutes();
      await manager.releaseTunnel();
      expect(windows.dns[_tunIndex], '10.8.0.1');
      final restore = windows.calls.singleWhere(
        (call) => call.dnsRestore(_tunIndex),
      );
      expect(restore.script, contains("-ServerAddresses @('10.8.0.1')"));
      expect(restore.script, isNot(contains('-ResetServerAddresses')));
      await manager.disable();
    });

    test('empty or incomplete DNS snapshot fails before mutations', () async {
      for (final snapshot in ['', '7;static;192.168.1.53', '42;dhcp;']) {
        final windows = _Windows()..dnsSnapshot = snapshot;
        final manager = windows.manager();
        await manager.enable();
        final start = windows.calls.length;
        await expectLater(manager.takeoverRoutes(), throwsStateError);
        expect(
          windows.calls
              .skip(start)
              .where(
                (call) =>
                    call.isRoute ||
                    call.script.contains('Set-DnsClientServerAddress'),
              ),
          isEmpty,
        );
        expect(manager.takeoverActive, isFalse);
        await manager.disable();
      }
    });

    test('invalid custom DNS is rejected before any commands', () async {
      final windows = _Windows();
      final manager = windows.manager();
      await manager.enable();
      for (final server in [
        'dns.example',
        '',
        "1.1.1.1'; Write-Output bad",
        '999.1.1.1',
      ]) {
        final count = windows.calls.length;
        await expectLater(
          manager.takeoverRoutes(customDnsServer: server),
          throwsArgumentError,
        );
        expect(windows.calls, hasLength(count));
      }
      await manager.disable();
    });

    test(
      'accepts IPv6 custom DNS literal with successful empty command output',
      () async {
        final windows = _Windows();
        final manager = windows.manager();
        await manager.enable();
        await manager.takeoverRoutes(customDnsServer: '2001:4860:4860::8888');
        expect(manager.takeoverActive, isTrue);
        expect(windows.dns.values, everyElement('2001:4860:4860::8888'));
        await manager.disable();
      },
    );

    test('missing tunnel has a single short mocked wait and throws', () async {
      final windows = _Windows()..tunnel = '';
      final manager = windows.manager();
      await manager.enable();
      final start = windows.calls.length;
      await expectLater(manager.takeoverRoutes(), throwsStateError);
      expect(windows.calls.skip(start), hasLength(1));
      expect(windows.splitAdds, isEmpty);
      await manager.disable();
    });
  });

  group('retryable rollback ownership', () {
    test(
      'failed split rollback blocks enable until release succeeds',
      () async {
        final windows = _Windows()
          ..failNext((call) => call.route('add', '128.0.0.0', '128.0.0.0'))
          ..failNext((call) => call.route('delete', '0.0.0.0', '128.0.0.0'));
        final manager = windows.manager();
        await manager.enable();
        await expectLater(manager.takeoverRoutes(), throwsStateError);
        expect(manager.takeoverActive, isTrue);
        final count = windows.calls.length;
        await expectLater(manager.enable(), throwsStateError);
        await expectLater(manager.takeoverRoutes(), throwsStateError);
        expect(windows.calls, hasLength(count));
        await manager.releaseTunnel();
        expect(manager.takeoverActive, isFalse);
        expect(windows.splitDeletes, hasLength(2));
        expect(
          windows.splitDeletes.first.arguments,
          windows.splitDeletes.last.arguments,
        );
        await manager.takeoverRoutes();
        expect(manager.takeoverActive, isTrue);
        await manager.disable();
      },
    );

    test(
      'failed DNS restore retains snapshot and retries only pending indices',
      () async {
        final windows = _Windows()
          ..failNext((call) => call.dnsApply(_tunIndex))
          ..failNext((call) => call.dnsRestore(_tunIndex));
        final manager = windows.manager();
        await manager.enable();
        await expectLater(manager.takeoverRoutes(), throwsStateError);
        expect(manager.takeoverActive, isTrue);
        expect(windows.dns[_tunIndex], _mapdns);
        final start = windows.calls.length;
        await manager.releaseTunnel();
        final retry = windows.calls.skip(start).toList();
        expect(retry, hasLength(2));
        expect(
          retry.first.script,
          contains('-InterfaceIndex $_tunIndex -ResetServerAddresses'),
        );
        expect(retry.last.script, endsWith('Clear-DnsClientCache'));
        expect(windows.dns[_tunIndex], 'dhcp');
        expect(manager.takeoverActive, isFalse);
        expect(
          windows.calls.where((call) => call.dnsRestore(_physicalIndex)),
          hasLength(1),
        );
        expect(windows.calls.where((call) => call.dnsRestore(8)), hasLength(1));
        await manager.disable();
      },
    );

    test(
      'release deletion failure keeps takeover pending and disable retries',
      () async {
        final windows = _Windows();
        final manager = windows.manager();
        await manager.enable();
        await manager.takeoverRoutes();
        windows.failNext(
          (call) => call.route('delete', '128.0.0.0', '128.0.0.0'),
        );
        await expectLater(manager.releaseTunnel(), throwsStateError);
        expect(manager.takeoverActive, isTrue);
        expect(manager.isActive, isTrue);
        final start = windows.calls.length;
        await manager.disable();
        final retry = windows.calls.skip(start).toList();
        expect(retry.first.arguments, [
          'delete',
          '128.0.0.0',
          'mask',
          '128.0.0.0',
          '0.0.0.0',
          'if',
          '$_tunIndex',
        ]);
        expect(retry.where((call) => call.dnsRestore(_tunIndex)), isEmpty);
        expect(manager.takeoverActive, isFalse);
        expect(manager.isActive, isFalse);
        expect(windows.routes, isEmpty);
      },
    );

    test(
      'failed restore cache flush remains pending without repeating successful restores',
      () async {
        final windows = _Windows();
        final manager = windows.manager();
        await manager.enable();
        await manager.takeoverRoutes();
        windows.failNext(
          (call) => call.script.endsWith('Clear-DnsClientCache'),
        );
        await expectLater(manager.releaseTunnel(), throwsStateError);
        expect(manager.takeoverActive, isTrue);
        final start = windows.calls.length;
        await expectLater(manager.enable(), throwsStateError);
        await manager.releaseTunnel();
        final retry = windows.calls.skip(start).toList();
        expect(retry, hasLength(1));
        expect(retry.single.script, endsWith('Clear-DnsClientCache'));
        expect(manager.takeoverActive, isFalse);
        await manager.disable();
      },
    );

    test(
      'apply cache flush failure throws and restores DNS and routes',
      () async {
        final windows = _Windows()
          ..failNext((call) => call.script.endsWith('Clear-DnsClientCache'));
        final manager = windows.manager();
        await manager.enable();
        await expectLater(manager.takeoverRoutes(), throwsStateError);
        expect(
          windows.calls.where(
            (call) => call.script.endsWith('Clear-DnsClientCache'),
          ),
          hasLength(2),
        );
        expect(windows.dns.values, isNot(contains(_mapdns)));
        expect(manager.takeoverActive, isFalse);
        await manager.disable();
      },
    );

    test(
      'failed bypass cleanup preserves physical identity for disable retry',
      () async {
        final windows = _Windows();
        final manager = windows.manager();
        await manager.enable();
        windows.failNext(
          (call) => call.route('delete', '1.1.1.1', '255.255.255.255'),
        );
        await expectLater(manager.disable(), throwsStateError);
        expect(manager.isActive, isTrue);
        expect(windows.routes, {
          '1.1.1.1|255.255.255.255|$_gateway|$_physicalIndex',
        });
        final start = windows.calls.length;
        await expectLater(manager.enable(), throwsStateError);
        await manager.disable();
        expect(windows.calls.skip(start), hasLength(1));
        expect(windows.calls.last.arguments, [
          'delete',
          '1.1.1.1',
          'mask',
          '255.255.255.255',
          _gateway,
          'if',
          '$_physicalIndex',
        ]);
        expect(manager.isActive, isFalse);
        expect(windows.routes, isEmpty);
      },
    );

    test(
      'never deletes unrelated bypasses or routes whose add failed',
      () async {
        final windows = _Windows();
        const otherGateway = '1.1.1.1|255.255.255.255|192.168.4.1|7';
        const otherInterface = '1.1.1.1|255.255.255.255|$_gateway|9';
        const preexisting =
            '203.0.113.11|255.255.255.255|$_gateway|$_physicalIndex';
        windows.routes.addAll([otherGateway, otherInterface, preexisting]);
        final manager = windows.manager();
        await manager.enable();
        expect(await manager.ensureBypassHost('203.0.113.11'), isNull);
        await manager.disable();
        expect(windows.routes, {otherGateway, otherInterface, preexisting});
        for (final call in windows.calls.where(
          (call) => call.isRoute && call.arguments[0] == 'delete',
        )) {
          expect(call.arguments[3], '255.255.255.255');
          expect(call.arguments[4], _gateway);
          expect(call.arguments.last, '$_physicalIndex');
          expect(call.arguments[1], isNot('203.0.113.11'));
        }
      },
    );
  });

  group('on-demand bypass resolution', () {
    test(
      'failed add returns null and subsequent retry can install it',
      () async {
        final windows = _Windows()
          ..answers['edge.example'] = [InternetAddress('203.0.113.12')];
        final manager = windows.manager();
        await manager.enable();
        windows.failNext(
          (call) => call.route('add', '203.0.113.12', '255.255.255.255'),
        );
        expect(await manager.ensureBypassHost('edge.example'), isNull);
        expect(
          windows.routes,
          isNot(
            contains('203.0.113.12|255.255.255.255|$_gateway|$_physicalIndex'),
          ),
        );
        expect(await manager.ensureBypassHost('edge.example'), '203.0.113.12');
        final count = windows.calls.length;
        expect(await manager.ensureBypassHost('EDGE.EXAMPLE'), '203.0.113.12');
        expect(windows.calls, hasLength(count));
        await manager.disable();
      },
    );

    test(
      'process spawn failure returns null for bypass, throws for takeover',
      () async {
        final windows = _Windows();
        final manager = windows.manager();
        await manager.enable();
        windows.failNext(
          (call) => call.route('add', '203.0.113.13', '255.255.255.255'),
          throwProcessException: true,
        );
        expect(await manager.ensureBypassHost('203.0.113.13'), isNull);
        windows.failNext(
          (call) => call.route('add', '128.0.0.0', '128.0.0.0'),
          throwProcessException: true,
        );
        await expectLater(
          manager.takeoverRoutes(),
          throwsA(isA<ProcessException>()),
        );
        expect(manager.takeoverActive, isFalse);
        await manager.disable();
      },
    );

    test(
      'rejects fake IPv4 literals and lookup answers without installing routes',
      () async {
        final windows = _Windows()
          ..answers['fake.example'] = [
            InternetAddress('100.64.0.1'),
            InternetAddress('100.127.255.254'),
            InternetAddress('2001:db8::1'),
          ];
        final manager = windows.manager();
        await manager.enable(extraBypassHosts: ['100.64.0.5', 'fake.example']);
        final count = windows.calls.length;
        for (final host in [
          '100.64.0.1',
          '100.127.255.254',
          'fake.example',
          '2001:db8::1',
        ]) {
          expect(await manager.ensureBypassHost(host), isNull);
        }
        expect(windows.calls, hasLength(count));
        expect(windows.lookups, isNot(contains('100.64.0.5')));
        expect(windows.lookups, isNot(contains('100.64.0.1')));
        expect(
          windows.routes.any((route) => route.startsWith('100.')),
          isFalse,
        );
        await manager.disable();
      },
    );

    test(
      'uses pre-tunnel cached real answer after resolver turns synthetic',
      () async {
        final windows = _Windows()
          ..answers['edge.example'] = [InternetAddress('203.0.113.14')];
        final manager = windows.manager();
        await manager.enable(extraBypassHosts: ['edge.example']);
        windows.answers['edge.example'] = [InternetAddress('100.64.0.9')];
        await manager.takeoverRoutes();
        final count = windows.lookups.length;
        expect(
          await manager.ensureBypassHost(' Edge.Example '),
          '203.0.113.14',
        );
        expect(windows.lookups, hasLength(count));
        await manager.disable();
      },
    );
  });
}
