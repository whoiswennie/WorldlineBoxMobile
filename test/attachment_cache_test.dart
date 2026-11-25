import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worldlinebox_mobile/attachment_cache.dart';

void main() {
  late Directory temp;
  const message = {
    'conversationId': 'room',
    'id': 'msg',
    'sequence': 1,
    'senderId': 'companion',
  };
  final bytes = utf8.encode('received original');
  final attachment = {
    'id': 'file',
    'size': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  };
  setUp(
    () async =>
        temp = await Directory.systemTemp.createTemp('attachment-cache-test'),
  );
  tearDown(() async => temp.delete(recursive: true));

  test(
    'preview, save and offline restart share one verified original per pairing',
    () async {
      final cache = AttachmentCache('pc', 'pairing', base: temp);
      var downloads = 0;
      final release = Completer<void>();
      Future<void> fetch(File file) async {
        downloads++;
        await release.future;
        await file.writeAsBytes(bytes);
      }

      final preview = cache.obtain(message, attachment, fetch);
      final save = cache.obtain(message, attachment, fetch);
      release.complete();
      expect((await preview).file.path, (await save).file.path);
      expect(downloads, 1);

      final restarted = AttachmentCache('pc', 'pairing', base: temp);
      final offline = await restarted.obtain(
        message,
        attachment,
        (_) => throw StateError('offline'),
      );
      expect(await offline.file.readAsBytes(), bytes);
      expect(restarted.offlineMessages('room').single['attachments'], [
        attachment,
      ]);
      final other = AttachmentCache('pc', 'new pairing', base: temp);
      await other.ready;
      expect(other.entries, isEmpty);
      await restarted.clear();
      expect(await offline.file.exists(), isFalse);
    },
  );

  test(
    'truncated, corrupt and interrupted transfers never become cached previews',
    () async {
      final cache = AttachmentCache('pc', 'token', base: temp);
      for (final contents in [
        bytes.take(3).toList(),
        List<int>.filled(bytes.length, 0),
      ]) {
        await expectLater(
          cache.obtain(message, attachment, (f) async {
            await f.writeAsBytes(contents);
          }),
          throwsA(anything),
        );
        expect(cache.entries, isEmpty);
      }
      await expectLater(
        cache.obtain(
          message,
          attachment,
          (_) => throw SocketException('disconnected'),
        ),
        throwsA(isA<SocketException>()),
      );
      final original = await cache.obtain(message, attachment, (f) async {
        await f.writeAsBytes(bytes);
      });
      await original.file.delete();
      var downloads = 0;
      await cache.obtain(message, attachment, (f) async {
        downloads++;
        await f.writeAsBytes(bytes);
      });
      expect(downloads, 1);
    },
  );
}
