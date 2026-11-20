import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

class WebSocketSsh implements SSHSocket {
  WebSocketSsh._(this._websocket);
  final WebSocket _websocket;
  final _done = Completer<void>();
  late final _incoming = StreamController<Uint8List>();
  late final _outgoing = StreamController<List<int>>();
  bool _closed = false;

  static Future<WebSocketSsh> connect(String host) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final ws = await WebSocket.connect(
        'wss://$host/worldlinebox-ssh',
        customClient: client,
      ).timeout(const Duration(seconds: 18));
      final socket = WebSocketSsh._(ws);
      ws.pingInterval = const Duration(seconds: 25);
      ws.listen(
        (data) {
          if (data is List<int> && !socket._closed) {
            socket._incoming.add(
              data is Uint8List ? data : Uint8List.fromList(data),
            );
          }
        },
        onError: (Object error, StackTrace stack) {
          if (!socket._closed) socket._incoming.addError(error, stack);
          socket.destroy();
        },
        onDone: socket.destroy,
      );
      socket._outgoing.stream.listen((data) {
        if (!socket._closed) {
          for (var offset = 0; offset < data.length; offset += 65536) {
            final end = (offset + 65536).clamp(0, data.length);
            ws.add(data.sublist(offset, end));
          }
        }
      });
      return socket;
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  // Only temporary Quick Tunnels are disposable. A DNS or network failure
  // alone is inconclusive. Check the provider's explicit no-tunnel response.
  static Future<bool> expiredTemporaryAddress(String host) async {
    if (!RegExp(r'^[a-z0-9-]+\.trycloudflare\.com$').hasMatch(host)) return false;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(Uri.https(host, '/worldlinebox-ssh'));
      request.followRedirects = false;
      final response = await request.close().timeout(const Duration(seconds: 6));
      if (response.statusCode != 530 || response.headers.value('cf-ray') == null) return false;
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 5))) {
        bytes.addAll(chunk.take(65536 - bytes.length));
        if (bytes.length >= 65536) break;
      }
      return RegExp(r'\b(1033|1016)\b').hasMatch(String.fromCharCodes(bytes));
    } on SocketException {
      // A local DNS failure alone could just mean the phone is offline.
      try {
        final lookup = await client.getUrl(Uri.https('cloudflare-dns.com', '/dns-query', {'name': host, 'type': 'A'}));
        lookup.headers.set(HttpHeaders.acceptHeader, 'application/dns-json');
        lookup.followRedirects = false;
        final response = await lookup.close().timeout(const Duration(seconds: 5));
        if (response.statusCode != 200) return false;
        final data = jsonDecode(await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 5)));
        return data is Map && data['Status'] == 3 && data['TC'] == false &&
            data['Question'] is List && (data['Question'] as List).whereType<Map>().any((q) => q['name'] == '$host.' && q['type'] == 1) &&
            data['Authority'] is List && (data['Authority'] as List).whereType<Map>().any((r) => r['name'] == 'trycloudflare.com.' && r['type'] == 6);
      } catch (_) { return false; }
    } catch (_) { return false; } finally { client.close(force: true); }
  }

  @override
  Stream<Uint8List> get stream => _incoming.stream;
  @override
  StreamSink<List<int>> get sink => _outgoing.sink;
  @override
  Future<void> get done => _done.future;
  @override
  Future<void> flush() async {
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> close() async => destroy();
  @override
  void destroy() {
    if (_closed) return;
    _closed = true;
    unawaited(_websocket.close().then<void>((_) {}, onError: (Object _) {}));
    unawaited(_incoming.close());
    unawaited(_outgoing.close());
    _done.complete();
  }
}
