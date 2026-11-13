import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:worldlinebox_mobile/mobile_api.dart';
import 'package:worldlinebox_mobile/profile.dart';

void main() {
  final fixture =
      Platform.environment['WORLDLINEBOX_PUBLIC_ATTACHMENT_FIXTURE'];
  test(
    'resumes a public SSH upload and receives the native DSH result',
    () async {
      final pairing = object(jsonDecode(await File(fixture!).readAsString()));
      final token =
          const Uuid().v4().replaceAll('-', '') +
          const Uuid().v4().replaceAll('-', '');
      final profile = HostProfile(
        host: pairing['host'] as String,
        sshPort: pairing['sshPort'] as int,
        username: 'mobile',
        fingerprint: pairing['fingerprint'] as String,
        apiPort: pairing['apiPort'] as int,
        token: token,
        transport: pairing['transport'] as String,
      );
      expect(profile.transport, 'wss');
      var api = await MobileApi.connect(
        profile,
        pairingCode: pairing['code'] as String,
        deviceName: '附件验收手机',
      );
      StreamSubscription<Json>? subscription;
      try {
        final directory = object((await api.request('state'))['snapshot']);
        final room =
            objects(directory['conversations']).firstWhere(
                  (item) =>
                      (item['memberIds'] as List).contains('builtin-dafeiyu'),
                )['id']
                as String;
        final topic = object(
          (await api.request('topic.new', {
            'conversationId': room,
            'requestId': const Uuid().v4(),
          }))['topic'],
        )['id'];
        final input = Uint8List.fromList([
          ...utf8.encode('n\n1\n2\n3\n'),
          ...List.filled(270000, 32),
        ]);
        final upload = const Uuid().v4();
        const offset = 256 * 1024;
        final first = await api.uploadPart(
          room,
          upload,
          'input.csv',
          input.length,
          0,
          Uint8List.sublistView(input, 0, offset),
        );
        expect(first['offset'], offset);
        await api.close();
        api = await MobileApi.connect(profile);
        expect((await api.uploadStatus(room, upload))['offset'], offset);
        final complete = await api.uploadPart(
          room,
          upload,
          'input.csv',
          input.length,
          offset,
          Uint8List.sublistView(input, offset),
        );
        expect(complete['offset'], input.length);
        final attachment = object(complete['attachment']);
        expect(attachment['size'], input.length);
        expect(
          (await api.uploadStatus(room, upload))['attachment'],
          attachment,
        );

        final ready = Completer<void>();
        final observed = <Json>[];
        subscription = api
            .events(room)
            .listen(
              (event) {
                observed.add(event);
                if (event['type'] == 'ready' && !ready.isCompleted) {
                  ready.complete();
                }
              },
              onError: (Object error, StackTrace stack) {
                if (!ready.isCompleted) ready.completeError(error, stack);
              },
            );
        await ready.future.timeout(const Duration(seconds: 25));
        final request = {
          'conversationId': room,
          'topicId': topic,
          'requestId': const Uuid().v4(),
          'content':
              'WLB_MOBILE_ATTACHMENT_ACCEPTANCE 请读取 input.csv 并交付 result.csv。',
          'attachmentIds': [attachment['id']],
        };
        final sent = await api.request('message.send', request);
        expect(
          (await api.request('message.send', request))['messageId'],
          sent['messageId'],
        );
        final replyId = (sent['replyMessageIds'] as List).single as String;
        final stopwatch = Stopwatch()..start();
        Json? reply;
        while (stopwatch.elapsed < const Duration(minutes: 3)) {
          final state = object(
            (await api.request('state', {
              'conversationId': room,
              'tracked': [replyId],
            }))['snapshot'],
          );
          reply = objects(
            state['messages'],
          ).where((item) => item['id'] == replyId).firstOrNull;
          if (reply?['status'] == 'failed') {
            fail(reply?['error'] as String? ?? 'Native reply failed');
          }
          if (reply?['status'] == 'sent') break;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        expect(reply?['status'], 'sent');
        expect(
          observed.any(
            (event) =>
                event['type'] == 'progress' && event['messageId'] == replyId,
          ),
          isTrue,
        );
        expect(
          observed.any(
            (event) => event['type'] == 'text' && event['messageId'] == replyId,
          ),
          isTrue,
        );
        final output = objects(
          reply?['attachments'],
        ).singleWhere((item) => item['name'] == 'result.csv');
        final download = await api.download(
          room,
          replyId,
          output['id'] as String,
        );
        expect(await utf8.decoder.bind(download).join(), 'sum\n6\n');
      } finally {
        await api.close().timeout(const Duration(seconds: 10));
        await subscription?.cancel().timeout(const Duration(seconds: 10));
      }
    },
    skip: fixture == null
        ? 'Requires a public endpoint for an isolated desktop profile.'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
