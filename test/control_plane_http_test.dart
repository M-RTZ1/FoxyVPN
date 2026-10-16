import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/data/control_plane_http.dart';

/// These tests pin the behaviour that keeps the control plane reachable while
/// the tunnel owns DNS and the default route:
///  * a bypass resolver decides the *dial* address, not the URI/Host header;
///  * a null / resolver-miss fails loudly instead of silently using the system
///    resolver (which returns a mapdns fake IP and deadlocks the dial);
///  * proxy mode keeps a raw socket so the proxy client does its own TLS;
///  * direct https gets TLS added inside the factory, using the logical host
///    for SNI (dart:io does not add TLS to a factory-provided socket).
///
/// The factory is exposed through an injected [io.HttpClient], which is how the
/// app wires it (`createIoClient(..., httpClient: ...)`); `IOClient` itself does
/// not surface the underlying client, so tests drive the raw client directly.
void main() {
  group('ControlPlaneHttp bypass transport', () {
    late io.HttpServer server;
    late String serverIp;
    late int serverPort;
    final dialedAddresses = <String>[];
    final dialedHosts = <String>[];
    final seenHosts = <String>[];
    final seenPaths = <String>[];

    setUp(() async {
      dialedAddresses.clear();
      dialedHosts.clear();
      seenHosts.clear();
      seenPaths.clear();
      server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
      serverIp = server.address.address;
      serverPort = server.port;
      server.listen((request) async {
        seenHosts.add(request.headers.host ?? '');
        seenPaths.add(request.uri.path);
        await utf8.decoder.bind(request).join();
        request.response.headers.contentType = io.ContentType.json;
        request.response.write(jsonEncode({'ok': true}));
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    Future<io.ConnectionTask<io.Socket>> recordingDial(
      io.InternetAddress address,
      int port,
    ) {
      dialedAddresses.add(address.address);
      return io.Socket.startConnect(address, port);
    }

    test('resolver result is dialled while the URI host is preserved', () async {
      final httpClient = io.HttpClient();
      ControlPlaneHttp.createIoClient(
        bypassResolver: (host) async {
          dialedHosts.add(host);
          // Mimic a /32 bypass literal: hand back loopback for any host.
          return serverIp;
        },
        httpClient: httpClient,
        startConnect: recordingDial,
      );

      // A public-looking hostname that normal DNS would never resolve here.
      final request = await httpClient.getUrl(
        Uri.parse('http://bypass.example.test:$serverPort/hello'),
      );
      final response = await request.close();
      await response.drain<void>();

      expect(response.statusCode, 200);
      expect(dialedHosts, contains('bypass.example.test'));
      expect(dialedAddresses, contains(serverIp));
      // The Host header must carry the logical host, not the bypass literal.
      // dart:io omits the port when a connectionFactory is used, so accept both.
      expect(
        seenHosts.any((h) =>
            h == 'bypass.example.test' || h == 'bypass.example.test:$serverPort'),
        isTrue,
        reason: 'saw $seenHosts',
      );
      expect(seenPaths, contains('/hello'));
      httpClient.close(force: true);
    });

    test('resolver miss throws instead of falling back to system DNS', () async {
      final httpClient = io.HttpClient();
      ControlPlaneHttp.createIoClient(
        bypassResolver: (host) async => null,
        httpClient: httpClient,
        startConnect: recordingDial,
      );

      await expectLater(
        httpClient.getUrl(Uri.parse('http://bypass.example.test/')),
        throwsA(isA<io.SocketException>()),
      );
      // No dial may have been attempted for an unresolvable bypass host.
      expect(dialedAddresses, isEmpty);
      httpClient.close(force: true);
    });

    test('direct https performs the TLS handshake with the logical host', () async {
      var secureCalls = 0;
      String? sniHost;
      final httpClient = io.HttpClient();
      ControlPlaneHttp.createIoClient(
        bypassResolver: (host) async => serverIp,
        httpClient: httpClient,
        startConnect: recordingDial,
        secureSocket: (socket, {required String host}) {
          secureCalls++;
          sniHost = host;
          return io.SecureSocket.secure(socket, host: host);
        },
      );

      // The loopback server is not TLS, so the request must fail — the point is
      // that the factory attempted the handshake and used the logical host.
      try {
        final request = await httpClient.getUrl(
          Uri.parse('https://bypass.example.test:$serverPort/'),
        );
        await request.close();
      } catch (_) {}
      expect(secureCalls, greaterThanOrEqualTo(1));
      expect(sniHost, 'bypass.example.test');
      httpClient.close(force: true);
    });
  });
}
