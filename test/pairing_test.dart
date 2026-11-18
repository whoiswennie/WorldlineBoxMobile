// Keep compatibility with the Flutter material widgets used by the app.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:worldlinebox_mobile/pairing.dart';

void main() {
  testWidgets('pairing opens with the QR scanner and album options', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: PairingPage(onSave: (_, _) async {})),
    );
    expect(find.text('世界线盒子'), findsOneWidget);
    expect(find.text('连接电脑'), findsOneWidget);
    expect(find.text('扫描二维码'), findsOneWidget);
    expect(find.text('从相册选择二维码'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
