import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show Factory;
import 'package:flutter/gestures.dart'
    show EagerGestureRecognizer, OneSequenceGestureRecognizer;
// Keep compatibility with the Flutter material widgets used by the app.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'mobile_api.dart';
import 'app_brand.dart';
import 'message_inbox.dart';
import 'resumable_upload.dart';
import 'mobile_speech.dart';
import 'pet_call_bubble.dart';
import 'chat_cache.dart';
import 'pairing.dart';
import 'profile.dart';

part 'chat_view.dart';
part 'chat_controls.dart';
part 'chat_alerts.dart';
part 'pet_call.dart';

const _uuid = Uuid();
const _accent = Color(0xff6959a3);

class CompanionWorkspace extends StatefulWidget {
  const CompanionWorkspace({
    super.key,
    required this.profile,
    required this.onForget,
    required this.saveProfile,
    this.initialConnection,
  });
  final HostProfile profile;
  final Future<void> Function() onForget;
  final Future<void> Function(HostProfile) saveProfile;
  final MobileApi? initialConnection;

  @override
  State<CompanionWorkspace> createState() => _CompanionWorkspaceState();
}

class _CompanionWorkspaceState extends State<CompanionWorkspace>
    with WidgetsBindingObserver, RouteAware {
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  final _speech = MobileSpeech();
  final _quotes = <String, Json>{};
  String? _readingMessage;
  String? _recordingRoom;
  bool _dictating = false;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _drafts = <String, String>{};
  final _attachments = <String, List<Json>>{};
  final _outbox = <String, Json>{};
  final _streaming = <String, String>{};
  final _liveProgress = <String, Json>{};
  final _downloading = <String>{};
  final _cancelledDownloads = <String>{};
  final _imageCache = <String, Future<Uint8List>>{};
  MobileApi? _api;
  late HostProfile _profile = widget.profile;
  int _connectionVersion = 0;
  final _inbox = MessageInbox();
  late final Future<void> _cacheReady;
  bool _pushEnabled = false;
  bool _refreshing = false;
  bool _refreshAgain = false;
  bool _refreshJump = false;
  String? _activeCallRoom;
  Map<String, dynamic>? _pendingChat;
  ModalRoute<dynamic>? _observedRoute;
  bool _editingAddress = false;
  bool _checkingRoute = false;
  StreamSubscription<Json>? _events;
  Timer? _retry;
  int _reconnectFailures = 0;
  Timer? _refreshTimer;
  Timer? _poll;
  Json _directory = {};
  Json _snapshot = {};
  Json _identity = {};
  late final _cache = ChatCache(widget.profile.fingerprint);
  final _own = <String, List<Json>>{};
  final _recent = <String, Map<String, Json>>{};
  final _cursor = <String, int>{};
  Timer? _cacheWrite;
  Timer? _outboxRetry;
  int _outboxBackoff = 0;
  bool _draining = false;
  String? _room;
  String? _error;
  bool _contacts = false;
  bool _connecting = false;
  bool _sending = false;
  bool _uploading = false;
  bool _changingTopic = false;
  double? _uploadProgress;
  final _uploads = <String, Json>{};
  String? _uploadId;
  bool _uploadWaiting = false;
  int _roomGeneration = 0;
  int _refreshGeneration = 0;

  void _update(VoidCallback change) => setState(change);

  bool get _roomUploading =>
      _uploading &&
      (_uploadId == null || _uploads.values.any((job) => job['room'] == _room));

  bool get _online => _api != null;
  Json get _runtime => object(_snapshot['chatRuntime']);
  List<Json> get _messages {
    final hidden = (_runtime['hiddenMessageIds'] as List?)?.toSet() ?? {};
    final byId = <String, Json>{
      for (final message in [...?_own[_room], ...?_recent[_room]?.values])
        message['id'] as String: message,
    };
    return byId.values
        .where(
          (m) =>
              !hidden.contains(m['id']) &&
              m['senderId'] != 'task-service' &&
              (m['status'] != 'sent' ||
                  m['content'] != '' ||
                  objects(m['attachments']).isNotEmpty ||
                  m['execution'] != null),
        )
        .toList()
      ..sort((a, b) => (a['sequence'] as int).compareTo(b['sequence'] as int));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cacheReady = _restoreCache();
    messageChannel.setMethodCallHandler((call) async {
      if (call.method == 'open') await _takeChat();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_takeChat()));
    _poll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_online) unawaited(_refresh());
      unawaited(_checkRoute());
    });
    if (widget.initialConnection case final MobileApi api) {
      _api = api;
      _watchRoom();
      unawaited(_loadIdentity());
      unawaited(_refresh());
    } else {
      unawaited(_connect());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_takeChat());
      if (_online) {
        unawaited(_refresh());
        unawaited(_flushOutbox());
      } else {
        unawaited(_connect());
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null && route != _observedRoute) {
      workspaceRoutes.unsubscribe(this);
      _observedRoute = route;
      workspaceRoutes.subscribe(this, route);
    }
  }

  @override
  void didPopNext() => _markVisible();

  @override
  void dispose() {
    workspaceRoutes.unsubscribe(this);
    messageChannel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    _retry?.cancel();
    _refreshTimer?.cancel();
    _poll?.cancel();
    _cacheWrite?.cancel();
    _outboxRetry?.cancel();
    unawaited(_events?.cancel());
    unawaited(_api?.close());
    _composer.dispose();
    _composerFocus.dispose();
    unawaited(_speech.stop());
    if (_recordingRoom != null) {
      unawaited(MobileSpeech.channel.invokeMethod<void>('record.cancel'));
    }
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_connecting || _online || _editingAddress || !mounted) return;
    final version = _connectionVersion;
    _retry?.cancel();
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final api = await MobileApi.connect(_profile);
      if (!mounted || version != _connectionVersion) {
        await api.close();
        return;
      }
      await _useConnection(api);
    } catch (error) {
      if (!mounted || version != _connectionVersion) return;
      setState(() => _error = connectionError(error));
      _scheduleReconnect();
    } finally {
      if (mounted) setState(() => _connecting = false);
      if (mounted &&
          version != _connectionVersion &&
          !_editingAddress &&
          !_online) {
        _scheduleReconnect();
      }
    }
  }

  Future<void> _remember(HostProfile next) async {
    if (jsonEncode(_profile.toJson()) == jsonEncode(next.toJson())) return;
    await widget.saveProfile(next);
    if (mounted) _profile = next;
  }

  Future<void> _useConnection(MobileApi api) async {
    final version = _connectionVersion;
    try {
      await _remember(api.profile);
    } catch (_) {
      await api.close();
      rethrow;
    }
    if (!mounted || version != _connectionVersion) {
      await api.close();
      return;
    }
    final previous = _api;
    _retry?.cancel();
    setState(() {
      _api = api;
      _reconnectFailures = 0;
      _error = null;
      _imageCache.clear();
    });
    _watchRoom();
    unawaited(previous?.close());
    unawaited(_resumeUploads());
    unawaited(_loadIdentity());
    unawaited(_refresh());
    unawaited(_flushOutbox());
  }

  bool get _canSwitchRoute =>
      !_editingAddress &&
      !_sending &&
      !_uploading &&
      !_draining &&
      _downloading.isEmpty &&
      _readingMessage == null &&
      ModalRoute.of(context)?.isCurrent == true &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  Future<void> _checkRoute() async {
    final active = _api;
    if (active == null || _checkingRoute || !_canSwitchRoute) return;
    _checkingRoute = true;
    try {
      if (active.route.local) {
        final remote = await active.currentRemoteHost();
        if (mounted &&
            identical(_api, active) &&
            !_editingAddress &&
            remote != null &&
            remote != _profile.remoteHost) {
          await _remember(_profile.withRoutes(remote: remote));
        }
      } else {
        final local = await MobileApi.connect(_profile, localOnly: true);
        if (!mounted || !identical(_api, active) || !_canSwitchRoute) {
          await local.close();
          return;
        }
        await _useConnection(local);
      }
    } catch (_) {
      // The active route remains usable while another route is unavailable.
    } finally {
      _checkingRoute = false;
    }
  }

  Future<void> _scanAddress() async {
    if (_editingAddress) return;
    _editingAddress = true;
    _connectionVersion++;
    _retry?.cancel();
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (page) => PairingPage(
            saved: _profile,
            onSave: (profile, api) async {
              if (!mounted || !page.mounted) {
                await api.close();
                return;
              }
              await _useConnection(api);
              if (page.mounted) Navigator.pop(page);
            },
          ),
        ),
      );
    } finally {
      _editingAddress = false;
      if (mounted && !_online) _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _retry?.cancel();
    final delay = 1 << _reconnectFailures.clamp(0, 5);
    _reconnectFailures++;
    _retry = Timer(Duration(seconds: delay), () => unawaited(_connect()));
  }

  void _lost(MobileApi api) {
    if (!mounted || !identical(api, _api)) return;
    setState(() {
      _api = null;
      _error = '电脑连接已断开，正在尝试重连。';
    });
    unawaited(api.close());
    _scheduleReconnect();
  }

  void _watchRoom() {
    unawaited(_events?.cancel());
    final api = _api;
    final room = _room;
    if (api == null) return;
    final generation = _roomGeneration;
    void disconnected() {
      if (generation == _roomGeneration) _lost(api);
    }

    _events = api
        .events(room, inbox: api.supportsInbox)
        .listen(
          (event) {
            if (!mounted ||
                !identical(api, _api) ||
                generation != _roomGeneration) {
              return;
            }
            if (event['type'] == 'text') {
              final follow = _nearBottom;
              setState(
                () => _streaming[event['messageId'] as String] =
                    event['text'] as String,
              );
              if (follow) _jumpToLatest();
            } else if (event['type'] == 'progress') {
              setState(
                () => _liveProgress[event['messageId'] as String] = object(
                  event['progress'],
                ),
              );
            } else {
              _refreshTimer ??= Timer(const Duration(milliseconds: 180), () {
                _refreshTimer = null;
                unawaited(_refresh());
              });
            }
          },
          onError: (Object _) => disconnected(),
          onDone: disconnected,
          cancelOnError: true,
        );
  }

  Future<void> _refresh({bool jump = false}) async {
    _refreshAgain = true;
    _refreshJump |= jump;
    if (_refreshing) return;
    _refreshing = true;
    try {
      await _cacheReady;
      while (mounted && _refreshAgain) {
        final follow = _refreshJump;
        _refreshJump = _refreshAgain = false;
        await _refreshOnce(jump: follow);
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _refreshOnce({required bool jump}) async {
    final api = _api;
    if (api == null) return;
    final room = _room;
    final generation = ++_refreshGeneration;
    try {
      final value = await api.request('state', {
        'conversationId': ?room,
        'after': ?_cursor[room],
        if (api.supportsInbox) 'inboxAfter': _inbox.cursor ?? -1,
        if (room != null)
          'tracked': (_recent[room]?.values ?? const <Json>[])
              .where((item) => ['running', 'queued'].contains(item['status']))
              .map((item) => item['id'])
              .take(20)
              .toList(),
      });
      if (!mounted ||
          !identical(api, _api) ||
          room != _room ||
          generation != _refreshGeneration) {
        return;
      }
      final follow = jump || _nearBottom;
      final state = object(value['snapshot']);
      final rooms = objects(state['conversations']);
      final page = object(state['inbox']);
      final legacy = api.supportsInbox
          ? null
          : await _inbox.readLegacy(
              rooms,
              objects(
                state['companions'],
              ).map((c) => c['id'] as String).toSet(),
              (id, before) async => object(
                (await api.request('state', {
                  'conversationId': id,
                  'history': true,
                  'before': ?before,
                }))['snapshot'],
              ),
            );
      if (!mounted || !identical(_api, api) || room != _room) return;
      _markVisible();
      final visible = _visibleRoom;
      final alerts = legacy != null
          ? _inbox.applyLegacy(legacy.heads, legacy.messages, visible)
          : _inbox.apply(
              page,
              rooms.map((r) => r['id'] as String).toSet(),
              visible,
            );
      final pushAfter = page['pushAfter'] as int?;
      final wasEnabled = _pushEnabled;
      _pushEnabled = pushAfter != null;
      if (_pushEnabled != wasEnabled) {
        await _nativeAlert('configure', _pushEnabled);
      }
      if (!mounted) return;
      setState(() {
        _directory = {
          'companions': state['companions'],
          'conversations': state['conversations'],
        };
        if (room != null) {
          _snapshot = state;
          final messages = _recent.putIfAbsent(room, () => {});
          for (final message in objects(state['messages'])) {
            messages[message['id'] as String] = message;
          }
          final ordered = messages.values.toList()
            ..sort(
              (a, b) => (b['sequence'] as int).compareTo(a['sequence'] as int),
            );
          _recent.remove(room);
          _recent[room] = {
            for (final message in ordered.take(70))
              message['id'] as String: message,
          };
          while (_recent.length > 8) {
            final old = _recent.keys.first;
            _recent.remove(old);
            _cursor.remove(old);
          }
          if (state['cursor'] case final int latest) _cursor[room] = latest;
          final active = messages.values
              .where((item) => ['queued', 'running'].contains(item['status']))
              .map((item) => item['id'])
              .toSet();
          _streaming.removeWhere((key, _) => !active.contains(key));
          _liveProgress.removeWhere((key, _) => !active.contains(key));
        }
      });
      _openPendingChat();
      _markVisible();
      for (final alert in alerts.entries) {
        _presentMessage(alert.key, alert.value, pushAfter);
      }
      if (page['more'] == true) _refreshAgain = true;
      if (alerts.isNotEmpty || _pushEnabled != wasEnabled) {
        await _saveCache();
      } else {
        _scheduleCache();
      }
      if (room != null && follow) _jumpToLatest();
    } catch (error) {
      if (!mounted || room != _room || generation != _refreshGeneration) return;
      if (error is MobileException && error.status != null) {
        _show(error.message);
      } else {
        _lost(api);
      }
    }
  }

  bool get _nearBottom =>
      !_scroll.hasClients || _scroll.position.extentAfter < 100;

  void _jumpToLatest() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && _scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
  });

  void _selectRoom(String? room) {
    if (_room == room) {
      _markVisible();
      return;
    }
    unawaited(_speech.stop());
    if (_recordingRoom != null) {
      _recordingRoom = null;
      unawaited(MobileSpeech.channel.invokeMethod<void>('record.cancel'));
    }
    if (_room case final String previous) _drafts[previous] = _composer.text;
    _roomGeneration++;
    setState(() {
      _room = room;
      _snapshot = {};
      _streaming.clear();
      _liveProgress.clear();
      _imageCache.clear();
      _changingTopic = false;
    });
    _markVisible();
    _composer.text = _drafts[room] ?? '';
    _watchRoom();
    _jumpToLatest();
    unawaited(_refresh(jump: true));
  }

  void _show(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _action(String type, Json fields) async {
    final api = _api;
    if (api == null) return;
    try {
      await api.request(type, fields);
      await _refresh();
    } catch (error) {
      _show(connectionError(error));
    }
  }

  Future<void> _openCompanion(Json person) async {
    final existing = objects(_directory['conversations'])
        .where(
          (item) =>
              item['kind'] == 'direct' &&
              (item['memberIds'] as List?)?.contains(person['id']) == true,
        )
        .firstOrNull;
    if (existing != null) {
      _selectRoom(existing['id'] as String);
      return;
    }
    final api = _api;
    if (api == null) return;
    try {
      final response = await api.request('conversation.open', {
        'companionId': person['id'],
      });
      if (mounted) _selectRoom(response['conversationId'] as String);
    } catch (error) {
      _show(connectionError(error));
    }
  }

  Future<void> _send({String delivery = 'queue'}) async {
    final room = _room;
    if (room == null || _sending || _roomUploading || _changingTopic) return;
    final text = _composer.text.trim();
    final ids = (_attachments[room] ?? []).map((file) => file['id']).toList();
    final quote = _quotes[room];
    if (text.isEmpty && ids.isEmpty) return;
    final fields = <String, dynamic>{
      'conversationId': room,
      'content': text,
      'attachmentIds': ids,
      'delivery': delivery,
      if (quote?['id'] case final String quoteId) 'quoteMessageId': quoteId,
      if (object(_runtime['topic'])['id'] case final String topic)
        'topicId': topic,
    };
    if (_outbox.length >= 12) {
      _show('已有 12 条本机消息等待发送，请先连接电脑。');
      return;
    }
    final requestId = _uuid.v4();
    _outbox[requestId] = {...fields, 'requestId': requestId};
    final stagedFiles = _attachments.remove(room);
    setState(() => _sending = true);
    try {
      await _saveCache(requireDisk: true);
      if (!mounted) return;
      setState(() {
        if (identical(_quotes[room], quote)) _quotes.remove(room);
        if (_drafts[room]?.trim() == text) _drafts.remove(room);
        if (_room == room && _composer.text.trim() == text) _composer.clear();
      });
      _jumpToLatest();
      unawaited(_flushOutbox());
    } catch (_) {
      _outbox.remove(requestId);
      if (stagedFiles != null) {
        _attachments[room] = [...stagedFiles, ...?_attachments[room]];
      }
      _show('无法保存待发送消息，请清理手机存储后重试。');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _readMessage(String room, String id) async {
    final api = _api;
    if (api == null) return;
    if (_readingMessage == id) {
      await _speech.stop();
      return;
    }
    setState(() => _readingMessage = id);
    try {
      await _speech.play(api, room, id);
    } catch (error) {
      if (mounted) _show(connectionError(error));
    } finally {
      if (mounted && _readingMessage == id) {
        setState(() => _readingMessage = null);
      }
    }
  }

  Future<void> _dictate(String room) async {
    final api = _api;
    if (_dictating || (api == null && _recordingRoom == null)) return;
    if (_recordingRoom != null && _recordingRoom != room) return;
    setState(() => _dictating = true);
    try {
      if (_recordingRoom == null) {
        await _speech.stop();
        await MobileSpeech.channel.invokeMethod<void>('record');
        if (!mounted || _room != room) {
          await MobileSpeech.channel.invokeMethod<void>('record.cancel');
          return;
        }
        setState(() => _recordingRoom = room);
      } else {
        setState(() => _recordingRoom = null);
        final bytes = await MobileSpeech.channel.invokeMethod<Uint8List>(
          'record.stop',
        );
        if (bytes == null || bytes.length <= 44) return;
        if (api == null) {
          _show('电脑连接已断开，暂时无法转写。');
          return;
        }
        final text = await api.transcribe(room, bytes);
        if (!mounted) return;
        if (text.isEmpty) {
          _show('没有识别到文字。');
          return;
        }
        final existing = _room == room ? _composer.text : _drafts[room] ?? '';
        final draft = existing.isEmpty ? text : '$existing $text';
        if (_room == room) {
          _composer.value = TextEditingValue(
            text: draft,
            selection: TextSelection.collapsed(offset: draft.length),
          );
          _composerFocus.requestFocus();
        } else {
          _drafts[room] = draft;
        }
      }
    } catch (error) {
      if (mounted) _show(connectionError(error));
    } finally {
      if (mounted) setState(() => _dictating = false);
    }
  }

  Future<void> _flushOutbox() async {
    if (_draining || _outbox.isEmpty || !mounted) return;
    _outboxRetry?.cancel();
    _draining = true;
    try {
      final handled = <String>{};
      while (mounted) {
        final entry = _outbox.entries
            .where(
              (entry) =>
                  entry.value['error'] == null && !handled.contains(entry.key),
            )
            .firstOrNull;
        if (entry == null) return;
        handled.add(entry.key);
        final api = _api;
        if (api == null || !mounted) return;
        try {
          final receipt = await api.request(
            'message.send',
            {...entry.value}..remove('error'),
          );
          if (!mounted) return;
          final room = entry.value['conversationId'] as String;
          final message = object(receipt['message']);
          setState(() {
            _outbox.remove(entry.key);
            if (message['id'] is String && message['sequence'] is int) {
              final entries = _own.putIfAbsent(room, () => []);
              entries.removeWhere((item) => item['id'] == message['id']);
              entries.add(message);
              if (entries.length > 60) entries.removeAt(0);
              while (_own.length > 16) {
                _own.remove(_own.keys.firstWhere((key) => key != room));
              }
            }
          });
          _outboxBackoff = 0;
          await _saveCache();
          if (_room == room) unawaited(_refresh(jump: true));
        } catch (error) {
          if (!mounted) return;
          if (error is MobileException &&
              [400, 403, 404, 409, 413].contains(error.status)) {
            setState(() => entry.value['error'] = error.message);
            await _saveCache();
            continue;
          }
          _outboxBackoff = min(_outboxBackoff + 1, 5);
          _outboxRetry = Timer(
            Duration(seconds: 1 << _outboxBackoff),
            () => unawaited(_flushOutbox()),
          );
          return;
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _managePending(String id, {required bool retry}) async {
    final entry = _outbox[id];
    if (entry == null || _draining) return;
    setState(() {
      if (retry) {
        entry.remove('error');
      } else {
        _outbox.remove(id);
      }
    });
    await _saveCache();
    if (retry) unawaited(_flushOutbox());
  }

  Future<void> _pickFiles() async {
    final api = _api;
    final room = _room;
    if (api == null || room == null || _uploading || _sending) return;
    setState(() => _uploading = true);
    try {
      final selection = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: false,
      );
      if (selection == null || !mounted) return;
      for (final file in selection.files) {
        if ((_attachments[room]?.length ?? 0) +
                _uploads.values.where((u) => u['room'] == room).length >=
            16) {
          _show('每条消息最多 16 个附件。');
          break;
        }
        if (file.path == null || file.size > api.maxUploadBytes) {
          _show(
            '${file.name} · ${file.path == null ? "无法读取文件" : "单个文件最多 ${api.maxUploadBytes ~/ 1048576} MiB"}',
          );
          continue;
        }
        final stat = await File(file.path!).stat();
        _uploads[_uuid.v4()] = {
          'name': file.name,
          'path': file.path,
          'size': stat.size,
          'modified': stat.modified.millisecondsSinceEpoch,
          'room': room,
        };
      }
      await _saveCache(requireDisk: true);
    } catch (error) {
      _show(connectionError(error));
    } finally {
      if (mounted) {
        setState(() => _uploading = false);
        unawaited(_resumeUploads());
      }
    }
  }

  Future<void> _resumeUploads() async {
    if (!mounted || !_online || _uploading || _uploads.isEmpty) return;
    setState(() => _uploading = true);
    try {
      while (mounted && _uploads.isNotEmpty) {
        final entry = _uploads.entries.first;
        final job = entry.value,
            id = entry.key,
            room = job['room'] as String,
            size = job['size'] as int;
        setState(() {
          _uploadId = id;
          _uploadWaiting = false;
          _uploadProgress = 0;
        });
        try {
          final attachment = await resumeUpload(
            id: id,
            room: room,
            name: job['name'] as String,
            file: File(job['path'] as String),
            size: size,
            modified: job['modified'] as int,
            connection: () => _api,
            cancelled: () => !mounted || !_uploads.containsKey(id),
            progress: (done, waiting) {
              if (mounted) {
                setState(() {
                  _uploadProgress = size == 0 ? 1 : done / size;
                  _uploadWaiting = waiting;
                });
              }
            },
          );
          if (!mounted) return;
          if (attachment != null && _uploads.containsKey(id)) {
            final draft = _attachments.putIfAbsent(room, () => []);
            if (!draft.any((a) => a['id'] == attachment['id'])) {
              draft.add(attachment);
            }
          }
        } catch (error) {
          if (mounted) _show('${job['name']} · ${connectionError(error)}');
        }
        if (!mounted) return;
        _uploads.remove(id);
        await _saveCache();
      }
    } finally {
      if (mounted) {
        setState(() {
          _uploading = false;
          _uploadId = null;
          _uploadProgress = null;
        });
      }
    }
  }

  Future<void> _cancelUpload() async {
    final id = _uploadId, job = _uploads[_uploadId];
    if (id == null || job == null) return;
    setState(() => _uploads.remove(id));
    await _saveCache();
    try {
      await _api?.cancelUpload(job['room'] as String, id);
    } catch (_) {
      /* Abandoned parts expire on the desktop. */
    }
  }

  Future<Uint8List> _loadImage(Json message, Json attachment) async {
    final api = _api!;
    final response = await api.download(
      message['conversationId'] as String,
      message['id'] as String,
      attachment['id'] as String,
    );
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      bytes.add(chunk);
      if (bytes.length > 4 * 1024 * 1024) {
        throw const MobileException('图片过大，请下载查看。');
      }
    }
    return bytes.takeBytes();
  }

  Future<void> _download(Json message, Json attachment) async {
    final api = _api;
    if (api == null) return;
    final messageId = message['id'] as String;
    final id = attachment['id'] as String;
    final key = '$messageId/$id';
    if (_downloading.contains(key)) return;
    setState(() => _downloading.add(key));
    Directory? temporary;
    try {
      final name = (attachment['name'] as String).replaceAll(
        RegExp(r'[/\\<>:"|?*\x00-\x1f]'),
        '_',
      );
      temporary = await (await getTemporaryDirectory()).createTemp(
        'worldlinebox-download-',
      );
      final file = File('${temporary.path}${Platform.pathSeparator}attachment');
      await file.create();
      final size = attachment['size'] as int;
      if (size == 0) {
        final response = await api.download(
          message['conversationId'] as String,
          messageId,
          id,
        );
        await response.drain<void>();
      }
      int failures = 0;
      while (mounted &&
          !_cancelledDownloads.contains(key) &&
          await file.length() < size) {
        final offset = await file.length();
        try {
          final active = _api;
          if (active == null) throw const SocketException('offline');
          final response = await active.download(
            message['conversationId'] as String,
            messageId,
            id,
            offset: offset,
          );
          if (response.statusCode == 206 &&
              response.headers.value(HttpHeaders.contentRangeHeader) !=
                  'bytes $offset-${size - 1}/$size') {
            throw const MobileException('下载分段与原文件不一致。', status: 400);
          }
          final append = response.statusCode == 206;
          final output = await file.open(
            mode: append ? FileMode.append : FileMode.write,
          );
          var written = append ? offset : 0;
          try {
            await for (final bytes in response.timeout(
              const Duration(seconds: 60),
            )) {
              if (!mounted || _cancelledDownloads.contains(key)) return;
              written += bytes.length;
              if (written > size) {
                throw const MobileException('文件大小校验失败。', status: 400);
              }
              await output.writeFrom(bytes);
            }
          } finally {
            await output.close();
          }
          if (written != size) {
            throw const SocketException('incomplete transfer');
          }
        } catch (error) {
          if (error is FileSystemException ||
              error is MobileException &&
                  error.status != null &&
                  error.status! < 500) {
            rethrow;
          }
          if (await file.length() > offset) failures = 0;
          failures++;
          await Future<void>.delayed(Duration(seconds: min(15, failures)));
        }
      }
      if (!mounted || _cancelledDownloads.contains(key)) return;
      if (attachment['sha256'] case final String expected) {
        final actual = await sha256.bind(file.openRead()).first;
        if (actual.toString() != expected) {
          throw const MobileException('文件内容校验失败。');
        }
      }
      if (!mounted) return;
      const files = MethodChannel('worldlinebox/mobile-files');
      final saved = await files.invokeMethod<bool>('save', {
        'name': name,
        'path': file.path,
        'mimeType': attachment['mimeType'],
      });
      if (saved == true) _show('附件已保存');
    } catch (error) {
      _show(connectionError(error));
    } finally {
      try {
        await temporary?.delete(recursive: true);
      } catch (_) {}
      _cancelledDownloads.remove(key);
      if (mounted) setState(() => _downloading.remove(key));
    }
  }

  Future<void> _restoreCache() async {
    final saved = await _cache.read();
    if (!mounted) return;
    setState(() {
      final inbox = object(saved['inbox']);
      _inbox.restore(inbox);
      final transfers = object(saved['transfers']);
      for (final entry in object(transfers['pending']).entries) {
        _uploads[entry.key] = object(entry.value);
      }
      for (final entry in object(transfers['drafts']).entries) {
        _attachments[entry.key] = objects(entry.value);
      }
      _pushEnabled = inbox['pushEnabled'] == true;
      if (_directory.isEmpty) _directory = object(saved['directory']);
      for (final entry in object(saved['own']).entries) {
        _own.putIfAbsent(entry.key, () => objects(entry.value));
      }
      for (final entry in object(saved['outbox']).entries) {
        final pending = object(entry.value);
        if (pending['requestId'] == entry.key &&
            pending['conversationId'] is String) {
          _outbox.putIfAbsent(entry.key, () => pending);
        }
      }
    });
    if (_pushEnabled) await _nativeAlert('configure', true);
    _openPendingChat();
    unawaited(_resumeUploads());
    unawaited(_flushOutbox());
  }

  Future<void> _loadIdentity() async {
    final api = _api;
    if (api == null) return;
    try {
      final identity = await api.request('user.identity');
      if (mounted && identical(api, _api)) setState(() => _identity = identity);
    } catch (_) {
      // The desktop may be offline while the workspace displays cached chat.
    }
  }

  Future<void> _editIdentity() async {
    final api = _api;
    if (api == null) return;
    await _loadIdentity();
    if (!mounted) return;
    final edited = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _IdentityDialog(
        name: _identity['userName'] as String? ?? '',
        bio: _identity['userBio'] as String? ?? '',
      ),
    );
    if (edited == null || !mounted) return;
    try {
      final saved = await api.request('user.identity', {
        'name': edited.$1,
        'bio': edited.$2,
      });
      if (mounted) setState(() => _identity = saved);
    } catch (error) {
      _show(connectionError(error));
    }
  }

  void _scheduleCache() {
    _cacheWrite ??= Timer(const Duration(seconds: 1), () {
      _cacheWrite = null;
      unawaited(_saveCache());
    });
  }

  Json get _transferJournal => {
    'pending': Map.of(_uploads),
    'drafts': {
      for (final e in _attachments.entries)
        if (e.value.isNotEmpty) e.key: List.of(e.value),
    },
  };

  Future<void> _saveCache({bool requireDisk = false}) async {
    try {
      await _cache.write(
        {
          'companions': objects(_directory['companions']),
          'conversations': objects(
            _directory['conversations'],
          ).map((item) => {...item}..remove('activity')).toList(),
        },
        _own.map(
          (key, items) => MapEntry(
            key,
            items
                .map(
                  (item) => {
                    ...item,
                    'content': (item['content'] as String? ?? '').characters
                        .take(900)
                        .toString(),
                  },
                )
                .toList(),
          ),
        ),
        outbox: _outbox,
        transfers: _transferJournal,
        inbox: {..._inbox.toJson(), 'pushEnabled': _pushEnabled},
      );
    } on FileSystemException {
      if (requireDisk) rethrow;
      /* Live chat remains usable if storage is full. */
    }
  }

  Future<void> _clearCache() async {
    _cacheWrite?.cancel();
    _cacheWrite = null;
    try {
      // Keep the delivery journal durable while clearing display data.
      await _cache.write(
        {},
        {},
        outbox: _outbox,
        transfers: _transferJournal,
        inbox: {..._inbox.toJson(), 'pushEnabled': _pushEnabled},
      );
      final support = await getApplicationSupportDirectory();
      final models = Directory('${support.path}/pet-model-files');
      if (await models.exists()) await models.delete(recursive: true);
      if (!mounted) return;
      setState(() {
        _own.clear();
        _recent.clear();
        _cursor.clear();
        _imageCache.clear();
        _directory = {};
      });
      _show('已清理此电脑的本地缓存。');
    } catch (_) {
      _show('无法清理本地缓存，请重试。');
    }
  }

  Future<void> _confirmClearCache() async {
    final clear = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理本地缓存'),
        content: const Text('删除本机保存的伙伴目录和发送记录。待发送消息、配对、电脑上的消息和已另存的附件会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (clear == true && mounted) await _clearCache();
  }

  @override
  Widget build(BuildContext context) => _workspace(context);
}
