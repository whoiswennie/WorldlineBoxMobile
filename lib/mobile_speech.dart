import 'dart:async';
import 'package:flutter/services.dart';
import 'mobile_api.dart';

class MobileSpeech {
  static const channel = MethodChannel('worldlinebox/pet-voice');
  static int _next = 0;
  int? _session;
  StreamSubscription<List<int>>? _stream;
  Completer<void>? _finished;

  Future<void> play(
    MobileApi api,
    String room,
    String message, {
    String? part,
    int? stage,
  }) async {
    await stop();
    final session = _session = ++_next;
    final finished = _finished = Completer<void>();
    try {
      await channel.invokeMethod<void>('start', {
        'id': session,
        'stage': ?stage,
      });
    } catch (_) {
      if (_session == session) await stop();
      rethrow;
    }
    if (_session != session) return;
    var tail = <int>[];
    late StreamSubscription<List<int>> stream;
    stream = api
        .speech(
          room,
          message,
          part: part,
          cancel: finished.future.then<void>((_) {}, onError: (Object _) {}),
        )
        .listen(
          (chunk) {
            stream.pause();
            unawaited(() async {
              try {
                final bytes = Uint8List.fromList([...tail, ...chunk]);
                final count = bytes.length & ~1;
                tail = bytes.sublist(count);
                for (
                  var offset = 0;
                  offset < count && _session == session;
                  offset += 8192
                ) {
                  final end = offset + 8192 < count ? offset + 8192 : count;
                  await channel.invokeMethod<void>('pcm', {
                    'id': session,
                    'bytes': Uint8List.sublistView(bytes, offset, end),
                  });
                }
                stream.resume();
              } catch (error, stack) {
                if (!finished.isCompleted) finished.completeError(error, stack);
              }
            }());
          },
          onError: (Object error, StackTrace stack) {
            if (!finished.isCompleted) finished.completeError(error, stack);
          },
          onDone: () {
            unawaited(() async {
              try {
                if (tail.isNotEmpty) throw const MobileException('音频数据不完整。');
                await channel
                    .invokeMethod<void>('drain', session)
                    .timeout(const Duration(seconds: 5));
                if (!finished.isCompleted) finished.complete();
              } catch (error, stack) {
                if (!finished.isCompleted) finished.completeError(error, stack);
              }
            }());
          },
        );
    _stream = stream;
    try {
      await finished.future;
    } finally {
      if (_session == session) await stop();
    }
  }

  Future<void> stop() async {
    final id = _session, stream = _stream, finished = _finished;
    _session = null;
    _stream = null;
    _finished = null;
    if (finished != null && !finished.isCompleted) finished.complete();
    if (id != null) await channel.invokeMethod<void>('stop', id);
    unawaited(stream?.cancel());
  }
}
