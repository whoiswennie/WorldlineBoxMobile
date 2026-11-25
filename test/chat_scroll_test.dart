import 'dart:async';
import 'dart:io';

import 'package:file/memory.dart';
// Use the same Material widgets as the application.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:worldlinebox_mobile/chat.dart';
import 'package:worldlinebox_mobile/computer_connection.dart';
import 'package:worldlinebox_mobile/mobile_api.dart';
import 'package:worldlinebox_mobile/profile.dart';

class _TestPaths extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async => '/support';
  @override
  Future<String?> getTemporaryPath() async => '/cache';
}

Json message(int i, String content, {List<Json>? cards}) => {
  'conversationId': 'room',
  'id': 'message-$i',
  'sequence': i + 1,
  'senderId': 'user',
  'content': content,
  'status': 'sent',
  'cards': ?cards,
};

class _ChatApi extends Fake implements MobileApi {
  final messages = <Json>[];
  Json? runtime = {
    'apps': ['music', 'video'],
  };
  var streams = 0;
  @override
  Future<Json> cardMusic(
    String room,
    String message,
    String card, {
    String? track,
  }) async {
    if (track == null) {
      return {
        'tracks': [
          {'id': 'track', 'name': '正在播放'},
        ],
      };
    }
    streams++;
    return {
      'stream': {'url': 'https://music.126.net/test.mp3'},
    };
  }

  final history = Completer<void>();
  final updates = StreamController<Json>.broadcast();
  @override
  bool get supportsInbox => true;
  @override
  bool get supportsTopicApps => true;
  @override
  ComputerRoute get route => (local: true, host: 'localhost', port: 1);
  @override
  Stream<Json> events(String? conversationId, {bool inbox = false}) =>
      updates.stream;
  @override
  Future<void> close() => updates.close();
  @override
  Future<Json> request(String type, [Json fields = const {}]) async {
    if (type == 'message.send') {
      final sent = message(messages.length, fields['content'] as String);
      messages.add(sent);
      return {'message': sent};
    }
    if (type != 'state') return {};
    final room = fields['conversationId'];
    if (room != null) await history.future;
    return {
      'snapshot': {
        'conversations': [
          {'id': 'room', 'title': '测试会话', 'kind': 'group'},
        ],
        'companions': [],
        'inbox': {'cursor': 0},
        'hasMore': true,
        'chatRuntime': ?runtime,
        if (room != null) 'messages': messages,
      },
    };
  }
}

Future<void> _withRoom(
  WidgetTester tester,
  _ChatApi api,
  Future<void> Function() check,
) async {
  final fs = MemoryFileSystem();
  final host = Zone.current;
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await IOOverrides.runZoned(
    () async {
      final platform = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPaths();
      addTearDown(() => PathProviderPlatform.instance = platform);
      const notifications = MethodChannel('worldlinebox/messages');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        notifications,
        (call) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          notifications,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: CompanionWorkspace(
            profile: const HostProfile(
              host: 'localhost',
              sshPort: 1,
              username: 'user',
              fingerprint: 'test',
              apiPort: 1,
              token: 'test',
            ),
            initialConnection: api,
            onForget: () async {},
            replacePairing: (_, _) async {},
            manageHosts: (_) async {},
            switchFromNotification: (_) async {},
            saveProfile: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试会话'));
      await tester.pumpAndSettle();
      expect(find.text('正在读取会话…'), findsOneWidget);
      api.history.complete();
      await tester.pumpAndSettle();

      await check();
      await tester.pumpWidget(const SizedBox.shrink());
    },
    createDirectory: (path) =>
        path.startsWith('/support') || path.startsWith('/cache')
        ? fs.directory(path)
        : host.run(() => Directory(path)),
    createFile: (path) => path.startsWith('/support')
        ? fs.file(path)
        : host.run(() => File(path)),
  );
}

void main() {
  testWidgets(
    'opens a room at the newest message after loading and on re-entry',
    (tester) async {
      final api = _ChatApi();
      for (var i = 0; i < 65; i++) {
        api.messages.add(
          message(i, i == 64 ? '最后一条消息' : '消息 $i\\n' * (1 + i % 5)),
        );
      }
      await _withRoom(tester, api, () async {
        final latest = find.text('最后一条消息').hitTestable();
        expect(latest, findsOneWidget);
        final timeline = find.byKey(const ValueKey('room')).first;
        final list = find
            .descendant(of: timeline, matching: find.byType(Scrollable))
            .first;
        await tester.drag(list, const Offset(0, 1100));
        await tester.pumpAndSettle();
        expect(latest, findsNothing);
        await tester.tap(find.byTooltip('返回伙伴'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('测试会话'));
        await tester.pumpAndSettle();
        expect(latest, findsOneWidget);
      });
    },
  );

  testWidgets(
    'ordinary messages retain the same player until a new playback request',
    (tester) async {
      final api = _ChatApi();
      api.messages.add(
        message(
          0,
          '已分享歌曲',
          cards: [
            {'kind': 'music', 'id': 'first-card', 'title': '歌曲'},
          ],
        ),
      );
      final created = <int>[], disposed = <int>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        final args = call.arguments as Map;
        if (call.method == 'create') {
          created.add(args['id'] as int);
          return 7;
        }
        if (call.method == 'dispose') disposed.add(args['id'] as int);
        if (call.method == 'resize') {
          return {'width': args['width'], 'height': args['height']};
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          SystemChannels.platform_views,
          null,
        ),
      );
      await _withRoom(tester, api, () async {
        await tester.tap(find.byTooltip('播放音乐'));
        await tester.pumpAndSettle();
        expect(created, hasLength(1));
        final music = created.single;
        await tester.enterText(find.byType(TextField), '继续聊天');
        await tester.tap(find.byTooltip('发送'));
        await tester.pumpAndSettle();
        expect(api.messages.last['content'], '继续聊天');
        expect(disposed, isEmpty);
        for (var i = 2; i < 76; i++) {
          api.messages.add(message(i, '普通回复 $i'));
        }
        api.runtime = null;
        api.updates.add({'type': 'changed'});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pumpAndSettle();
        expect(find.text('普通回复 75').hitTestable(), findsOneWidget);
        expect(api.streams, 1);
        expect(created, [music]);
        expect(disposed, isEmpty);

        api.messages.add(
          message(
            76,
            '视频',
            cards: [
              {
                'id': 'next-card',
                'kind': 'video',
                'title': '新视频',
                'player': 'https://player.bilibili.com/player.html',
              },
            ],
          ),
        );
        api.runtime = {
          'apps': ['music', 'video'],
        };
        api.updates.add({
          'type': 'video-present',
          'conversationId': 'room',
          'surface': 'chat',
          'cardId': 'next-card',
        });
        await tester.pumpAndSettle();
        expect(created, hasLength(2));
        expect(disposed, [music]);
      });
    },
  );
}
