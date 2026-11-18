import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:worldlinebox_mobile/computer_connection.dart';
import 'package:worldlinebox_mobile/mobile_api.dart';
import 'package:worldlinebox_mobile/pairing.dart';
import 'package:worldlinebox_mobile/profile.dart';

void main() {
  final fingerprint = 'SHA256:${'A' * 43}';
  final legacy = HostProfile.fromJson({
    'host': 'old.example.com',
    'sshPort': 443,
    'transport': 'wss',
    'username': 'mobile',
    'fingerprint': fingerprint,
    'apiPort': 47831,
    'token': 'saved-secret',
  });
  final invitation = {
    'protocol': 2,
    'code': 'c' * 64,
    'host': 'new.example.com',
    'sshPort': 443,
    'transport': 'wss',
    'fingerprint': fingerprint,
    'apiPort': 47831,
    'lan': {
      'hosts': ['192.168.1.7'],
      'port': 47832,
    },
  };
  test(
    'remote rescan keeps legacy authorization and LAN reconnection works after DHCP and port changes',
    () async {
      final updated = ComputerInvitation.parse(
        jsonEncode(invitation),
        'unused',
        saved: legacy,
      ).computer;
      final rebooted = HostProfile.fromJson(
        jsonDecode(jsonEncode(updated.toJson())),
      );
      expect(rebooted.token, legacy.token);
      expect(rebooted.remoteHost, 'new.example.com');
      expect(rebooted.localRoutes.single.host, '192.168.1.7');
      final route = await connectComputer(
        rebooted,
        (route) async => route,
        discover: (_) async => [(host: '192.168.1.30', port: 50999)],
      );
      expect(route, (host: '192.168.1.30', port: 50999, local: true));
      final localOnlyQr = {
        ...invitation,
        'host': route.host,
        'sshPort': route.port,
        'transport': null,
      };
      final refreshed = ComputerInvitation.parse(
        jsonEncode(localOnlyQr),
        'unused',
        saved: rebooted,
      ).computer;
      expect(refreshed.remoteHost, rebooted.remoteHost);
      expect(
        refreshed.localRoutes,
        contains((host: route.host, port: route.port)),
      );
      expect(refreshed.discoveryName, legacy.discoveryName);
    },
  );
  test('rejects address updates for a different computer', () {
    expect(
      () => ComputerInvitation.parse(
        jsonEncode({...invitation, 'fingerprint': 'SHA256:${'B' * 43}'}),
        '',
        saved: legacy,
      ),
      throwsA(isA<MobileException>()),
    );
  });
  test(
    'remote fallback retains local routes and skips stale LAN hints on cellular',
    () async {
      final profile = legacy.withRoutes(
        local: [(host: '192.168.4.7', port: 47832)],
      );
      final attempted = <String>[];
      Future<ComputerRoute> dial(ComputerRoute route) async {
        attempted.add(route.host);
        if (route.local) throw const SocketException('offline');
        return route;
      }

      expect(
        (await connectComputer(profile, dial, discover: (_) async => [])).local,
        false,
      );
      expect(attempted, ['192.168.4.7', 'old.example.com']);
      attempted.clear();
      await connectComputer(profile, dial, discover: (_) async => null);
      expect(attempted, ['old.example.com']);
      attempted.clear();
      await expectLater(
        connectComputer(
          profile,
          dial,
          localOnly: true,
          discover: (_) async => null,
        ),
        throwsA(isA<SocketException>()),
      );
      expect(attempted, isEmpty);
    },
  );
}
