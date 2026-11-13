import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:worldlinebox_mobile/mobile_api.dart';
import 'package:worldlinebox_mobile/profile.dart';

void main() {
  final fixturePath = Platform.environment['WORLDLINEBOX_SSH_TEST_FIXTURE'];
  test(
    'SSH authenticates the host and transports JSON, SSE and binary files',
    () async {
      final data = jsonDecode(await File(fixturePath!).readAsString()) as Json;
      final profile = HostProfile.fromJson(data);
      final changed = HostProfile.fromJson({
        ...data,
        'fingerprint': 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      });
      await expectLater(
        MobileApi.connect(changed),
        throwsA(isA<MobileException>()),
      );
      final api = await MobileApi.connect(profile);
      try {
        expect(await api.request('state'), containsPair('ok', true));
        expect(await api.events('test').first, containsPair('type', 'ready'));
        final bytes = utf8.encode('value\n1\n2\n');
        final attachment = await api.upload(
          'test',
          'input.csv',
          bytes.length,
          Stream.value(bytes),
        );
        final response = await api.download(
          'test',
          'message',
          attachment['id'] as String,
        );
        expect(await utf8.decoder.bind(response).join(), utf8.decode(bytes));
      } finally {
        await api.close();
      }
    },
    skip: fixturePath == null
        ? 'Set WORLDLINEBOX_SSH_TEST_FIXTURE to the isolated SSH fixture profile.'
        : false,
  );
}
