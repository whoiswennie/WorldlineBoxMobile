import 'dart:async';
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
