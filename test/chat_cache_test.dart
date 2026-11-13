import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:worldlinebox_mobile/chat_cache.dart';

void main() {
  test(
    'retains an undelivered message after re-opening and clearing display cache',
    () async {
      final root = await Directory.systemTemp.createTemp('wlb-mobile-cache-');
      try {
        final file = File('${root.path}/chat.json');
        final pending = {
          'retry-id': {
            'requestId': 'retry-id',
            'conversationId': 'test',
            'content': '消息',
          },
        };
        await ChatCache('test', file: file).write(
          {
            'companions': [
              {'id': 'test'},
            ],
          },
          {
            'test': [
              {'id': 'delivered'},
            ],
          },
          outbox: pending,
        );
        final reopened = ChatCache('test', file: file);
        expect((await reopened.read())['outbox'], pending);
        await reopened.write({}, {}, outbox: pending);
        expect(await reopened.read(), {
          'directory': {},
          'own': {},
          'outbox': pending,
        });
        await reopened.clear();
        expect(await reopened.read(), isEmpty);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
