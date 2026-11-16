import 'dart:async';
import 'dart:typed_data' show BytesBuilder;
import 'package:flutter/services.dart';
import 'mobile_api.dart';

class MobileSpeech {
  static const channel = MethodChannel('worldlinebox/pet-voice');
  // A second of mono 24 kHz, 16-bit PCM, matching the Android AudioTrack.
  static const _prebufferBytes = 48000;
  static const _writeBytes = 8192;
  static int _next = 0;
  int? _session;
  StreamSubscription<List<int>>? _stream;
  Completer<void>? _finished;

  Future<void> play(
    MobileApi api,
    String room,
    String message, {
    String? part,
    int? pageIndex,
    int? stage,
  }) async {
    await stop();
    final session = _session = ++_next;
    final finished = _finished = Completer<void>();
    final pending = BytesBuilder(copy: false);
    var started = false;

    Future<void> writePending() async {
      if (_session != session || pending.length < 2) return;
      if (!started) {
        await channel.invokeMethod<void>('start', {
          'id': session,
          'stage': ?stage,
        });
        started = true;
      }
      final bytes = pending.takeBytes();
      final count = bytes.length & ~1;
      if (count < bytes.length) pending.addByte(bytes.last);
      for (
        var offset = 0;
        offset < count && _session == session;
        offset += _writeBytes
      ) {
        final end = offset + _writeBytes < count ? offset + _writeBytes : count;
        await channel.invokeMethod<void>('pcm', {
          'id': session,
          'bytes': Uint8List.sublistView(bytes, offset, end),
        });
      }
    }

    late StreamSubscription<List<int>> stream;
    stream = api
        .speech(
          room,
          message,
          part: part,
          pageIndex: pageIndex,
          cancel: finished.future.then<void>((_) {}, onError: (Object _) {}),
        )
        .listen(
          (chunk) {
            pending.add(chunk);
            if (pending.length < (started ? _writeBytes : _prebufferBytes)) {
              return;
            }
            stream.pause();
            unawaited(() async {
              try {
                await writePending();
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
                if (pending.length.isOdd || (!started && pending.isEmpty)) {
                  throw const MobileException('音频数据不完整。');
                }
                await writePending();
                if (_session != session) return;
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
