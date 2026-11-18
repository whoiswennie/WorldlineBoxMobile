import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'mobile_api.dart';

/// A status read is authoritative even when the reply to the last PUT was lost.
Future<Json?> resumeUpload({
  required String id,
  required String room,
  required String name,
  required File file,
  required int size,
  required int modified,
  required MobileApi? Function() connection,
  required bool Function() cancelled,
  required void Function(int offset, bool waiting) progress,
  Future<void> Function(Duration) wait = Future<void>.delayed,
}) async {
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file ||
      stat.size != size ||
      stat.modified.millisecondsSinceEpoch != modified) {
    throw const MobileException('原文件已移动或更改，请重新选择。');
  }
  final source = await file.open();
  var offset = 0, chunk = 256 * 1024, failures = 0;
  var checkStatus = true;
  try {
    while (!cancelled()) {
      try {
        final api = connection();
        if (api == null) throw const SocketException('offline');
        if (size > api.maxUploadBytes) {
          throw MobileException(
            '这台电脑允许的单文件上限为 ${api.maxUploadBytes ~/ (1024 * 1024)} MiB。',
            status: 413,
          );
        }
        if (checkStatus) {
          final state = await api.uploadStatus(room, id);
          if (state['attachment'] != null) return object(state['attachment']);
          offset = state['offset'] as int;
          if (offset < 0 || offset > size) {
            throw const MobileException('电脑返回了无效的续传位置。', status: 400);
          }
          checkStatus = false;
        }
        if (cancelled()) return null;
        await source.setPosition(offset);
        final bytes = await source.read(
          min(size - offset, min(chunk, api.uploadChunkBytes)),
        );
        if (bytes.isEmpty && offset < size) {
          throw const MobileException('无法继续读取文件。', status: 400);
        }
        final timer = Stopwatch()..start();
        final reply = await api.uploadPart(room, id, name, size, offset, bytes);
        if (reply['attachment'] != null) return object(reply['attachment']);
        if (reply['offset'] != offset + bytes.length || bytes.isEmpty) {
          throw const MobileException('电脑未确认此分段。', status: 409);
        }
        offset += bytes.length;
        progress(offset, false);
        failures = 0;
        if (timer.elapsedMilliseconds < 1200) {
          chunk = min(api.uploadChunkBytes, chunk * 2);
        }
        if (timer.elapsedMilliseconds > 8000) {
          chunk = max(32 * 1024, chunk ~/ 2);
        }
      } catch (error) {
        if (error is FileSystemException ||
            (error is MobileException &&
                ([400, 401, 403, 404, 413, 507].contains(error.status) ||
                    (error.status == 500 && failures >= 5)))) {
          rethrow;
        }
        checkStatus = true;
        chunk = max(32 * 1024, chunk ~/ 2);
        failures++;
        progress(offset, true);
        await wait(Duration(seconds: min(15, 1 << min(failures - 1, 4))));
      }
    }
    return null;
  } finally {
    await source.close();
  }
}
