import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:worldlinebox_mobile/mobile_api.dart';
import 'package:worldlinebox_mobile/profile.dart';

void main() {
  final path = Platform.environment['WORLDLINEBOX_DESKTOP_SSH_TEST_FIXTURE'];
  test(
    'reads real desktop companion state and uploads a file over SSH',
    () async {
      final data = jsonDecode(await File(path!).readAsString()) as Json;
      final api = await MobileApi.connect(HostProfile.fromJson(data));
      try {
        final state = object((await api.request('state'))['snapshot']);
        final people = objects(state['companions']);
        expect(people, isNotEmpty);
        final room = objects(state['conversations']).first['id'] as String;
        final bytes = utf8.encode('n\n1\n2\n');
        final file = await api.upload(
          room,
          'mobile-transport.csv',
          bytes.length,
          Stream.value(bytes),
        );
        expect(file['size'], bytes.length);
        expect(
          await api.request('state', {'conversationId': room}),
          containsPair('ok', true),
        );
        expect(await api.events(room).first, containsPair('type', 'ready'));
      } finally {
        await api.close();
      }
    },
    skip: path == null
        ? 'Requires an isolated desktop profile and a local SSH fixture.'
        : false,
  );
}
