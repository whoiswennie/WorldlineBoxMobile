// Keep compatibility with the Flutter material widgets used by the app.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worldlinebox_mobile/pairing.dart';

void main() {
  testWidgets(
    'lists distinct nearby computers, including two with the same name',
    (tester) async {
      const channel = MethodChannel('worldlinebox/local-computers');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final first = {
        'name': '工作电脑',
        'host': '192.168.1.5',
        'port': 47832,
        'fingerprint': 'SHA256:${'A' * 43}',
      };
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => [
          first,
          first,
          {
            ...first,
            'host': '192.168.1.6',
            'fingerprint': 'SHA256:${'B' * 43}',
          },
        ],
      );
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        MaterialApp(home: PairingPage(onSave: (_, _) async {})),
      );
      await tester.pumpAndSettle();
      expect(find.text('工作电脑'), findsNWidgets(2));
      expect(find.text('192.168.1.5'), findsOneWidget);
      expect(find.text('192.168.1.6'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('pairing opens with the QR scanner and album options', (
    tester,
  ) async {
    const channel = MethodChannel('worldlinebox/local-computers');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => []);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      MaterialApp(home: PairingPage(onSave: (_, _) async {})),
    );
    await tester.pumpAndSettle();
    expect(find.text('世界线盒子'), findsOneWidget);
    expect(find.text('连接电脑'), findsOneWidget);
    expect(find.text('扫描二维码'), findsOneWidget);
    expect(find.text('从相册选择二维码'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
