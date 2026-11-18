import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:worldlinebox_mobile/message_inbox.dart';
import 'package:worldlinebox_mobile/mobile_api.dart';
import 'package:worldlinebox_mobile/resumable_upload.dart';

class _InterruptedConnection implements MobileApi {
  final received = <int>[];
  var interrupted = false;
  @override
  int get maxUploadBytes => 4 * 1024 * 1024;
  @override
  int get uploadChunkBytes => 64 * 1024;
  @override
  Future<Json> uploadStatus(String room, String id) async => {
    'offset': received.length,
  };
  @override
  Future<Json> uploadPart(
    String room,
    String id,
    String name,
    int total,
    int offset,
    List<int> bytes,
  ) async {
    expect(offset, received.length);
    received.addAll(bytes);
    if (!interrupted) {
      interrupted = true;
      throw const SocketException('confirmation lost');
    }
    return {
      'offset': received.length,
      if (received.length == total) 'attachment': {'id': id},
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'visible chat stays read and other chats retain counts across replay and restart',
    () {
      final inbox = MessageInbox();
      final rooms = {'one', 'two'};
      inbox.apply({'messages': [], 'cursor': 5}, rooms, null);
      final page = {
        'cursor': 9,
        'messages': [
          for (final n in [6, 7, 8])
            {'sequence': n, 'room': n == 6 ? 'one' : 'two', 'preview': 'hi'},
        ],
      };
      expect(inbox.apply(page, rooms, 'one').keys, ['two']);
      expect(inbox.unread, {'two': 2});
      final reopened = MessageInbox()..restore(inbox.toJson());
      expect(reopened.apply(page, rooms, null), isEmpty);
      expect(reopened.unread, {'two': 2});
      reopened.apply(page, rooms, 'two');
      expect(reopened.unread, isEmpty);
    },
  );

  test(
    'weak link resumes the acknowledged bytes after a lost reply and a longer disconnection',
    () async {
      final tmp = await Directory.systemTemp.createTemp('upload-source');
      try {
        final file = File('${tmp.path}/source.zip');
        final contents = List.generate(270000, (n) => n % 251);
        await file.writeAsBytes(contents);
        final api = _InterruptedConnection();
        var attempts = 0;
        final result = await resumeUpload(
          id: 'abc',
          room: 'room',
          name: 'source.zip',
          file: file,
          size: contents.length,
          modified: (await file.stat()).modified.millisecondsSinceEpoch,
          connection: () {
            attempts++;
            return attempts > 1 && attempts < 13 ? null : api;
          },
          cancelled: () => false,
          progress: (_, _) {},
          wait: (_) async {},
        );
        expect(result, {'id': 'abc'});
        expect(api.received, contents);
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );
}
