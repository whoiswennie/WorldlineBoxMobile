import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'profile.dart';
import 'computer_connection.dart';
import 'websocket_ssh.dart';

typedef Json = Map<String, dynamic>;

List<Json> objects(dynamic value) =>
    value is List ? value.whereType<Json>().toList() : [];
Json object(dynamic value) => value is Json ? value : const {};

class MobileException implements Exception {
  const MobileException(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

class MobileApi {
  MobileApi._(
    this._client,
    this._server,
    this._token,
    this.route,
    this.profile,
  );
  final ComputerRoute route;
  HostProfile profile;

  final SSHClient _client;
  final ServerSocket _server;
  final String _token;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 12);
  final Set<Socket> _sockets = {};
  bool _closed = false;
  int maxUploadBytes = 0;
  int uploadChunkBytes = 256 * 1024;
  bool supportsInbox = false;
  bool supportsTopicApps = false;
  bool attachmentThumbnails = false;
  bool downloadsOriginal = false;
  bool pagedSpeech = false;

  static Future<MobileApi> connect(
    HostProfile profile, {
    String? pairingCode,
    String? deviceName,
    bool localOnly = false,
  }) => connectComputer(
    profile,
    (route) => _dial(profile, route, pairingCode, deviceName),
    localOnly: localOnly,
  );

  static Future<MobileApi> pairNearby(HostProfile profile, String deviceName, Future<void> cancelled) async {
    final route = (host: profile.host, port: profile.sshPort, local: true);
    final socket = await SSHSocket.connect(route.host, route.port, timeout: const Duration(seconds: 4));
    final client = SSHClient(socket, username: 'nearby:$deviceName',
      onPasswordRequest: () => profile.token,
      onVerifyHostKey: (type, fingerprint) =>
          type == 'ssh-ed25519' && utf8.decode(fingerprint) == profile.fingerprint,
      algorithms: const SSHAlgorithms(hostkey: [SSHHostkeyType.ed25519]),
      handshakeTimeout: const Duration(seconds: 12), authTimeout: const Duration(seconds: 65));
    unawaited(client.done.then<void>((_) {}, onError: (Object _) {}));
    unawaited(cancelled.then((_) => client.close()));
    try {
      await client.authenticated;
    } catch (_) {
      throw const MobileException('电脑未批准连接，或请求已过期。请在两端核对连接码后重试。');
    } finally {
      client.close();
    }
    return _dial(profile, route, null, null);
  }

  static Future<MobileApi> _dial(
    HostProfile profile,
    ComputerRoute route,
    String? pairingCode,
    String? deviceName,
  ) async {
    final identities = <SSHKeyPair>[];
    try {
      if (profile.privateKey.isNotEmpty) {
        identities.addAll(
          SSHKeyPair.fromPem(
            profile.privateKey.trim(),
            profile.passphrase.isEmpty ? null : profile.passphrase,
          ),
        );
      }
    } catch (_) {
      throw const MobileException('无法读取 SSH 私钥，请检查文件和口令。');
    }

    final socket = !route.local
        ? await WebSocketSsh.connect(route.host)
        : await SSHSocket.connect(
            route.host,
            route.port,
            timeout: const Duration(seconds: 3),
          );
    var fingerprintMismatch = false;
    final client = SSHClient(
      socket,
      username: pairingCode == null ? profile.username : 'pair',
      onPasswordRequest: identities.isEmpty
          ? () => pairingCode ?? profile.token
          : null,
      identities: identities,
      onVerifyHostKey: (type, fingerprint) {
        final matches =
            type == 'ssh-ed25519' &&
            utf8.decode(fingerprint) == profile.fingerprint;
        fingerprintMismatch = !matches;
        return matches;
      },
      algorithms: const SSHAlgorithms(hostkey: [SSHHostkeyType.ed25519]),
      handshakeTimeout: const Duration(seconds: 15),
      authTimeout: const Duration(seconds: 15),
    );
    // Authentication and transport shutdown can both fail during the handshake.
    unawaited(client.done.then<void>((_) {}, onError: (Object _) {}));
    MobileApi? api;
    try {
      await client.authenticated;
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      api = MobileApi._(client, server, profile.token, route, profile);
      final connection = api;
      server.listen(
        (socket) => unawaited(connection._forward(socket, profile.apiPort)),
      );
      unawaited(
        client.done.then(
          (_) => connection.close(),
          onError: (Object _) => connection.close(),
        ),
      );
      if (pairingCode != null) {
        await api._json(
          'POST',
          'pair',
          data: {
            'code': pairingCode,
            'token': profile.token,
            'name': deviceName,
          },
        );
        await api.close();
        return await _dial(profile, route, null, null);
      }
      final health = await api._json('GET', 'health');
      if (health['protocol'] != 1) throw const MobileException('电脑端移动协议版本不兼容。');
      api.uploadChunkBytes =
          ((health['uploadChunkBytes'] as int?) ?? 256 * 1024).clamp(
            32 * 1024,
            1024 * 1024,
          );
      api.maxUploadBytes = health['maxUploadBytes'] as int;
      api.attachmentThumbnails = health['attachmentThumbnails'] == true;
      api.downloadsOriginal = health['downloadOriginal'] == true;
      api.supportsInbox = health['inbox'] == true;
      api.supportsTopicApps = health['topicApps'] == true;
      api.pagedSpeech = health['pagedSpeech'] == true;
      api.profile = profile.withRoutes(
        computerName: health['computerName'] as String?,
        remote: validRemoteHost(health['remoteHost'])
            ? health['remoteHost'] as String
            : null,
        local: [if (route.local) (host: route.host, port: route.port)],
      );
      return api;
    } catch (_) {
      if (api != null) {
        await api.close();
      } else {
        try {
          await client.close();
        } catch (_) {}
      }
      if (fingerprintMismatch) {
        throw const MobileException('SSH 主机指纹不匹配，请在电脑上重新核对。');
      }
      rethrow;
    }
  }

  Future<void> releasePairing() async { await _json('DELETE', 'profile'); }

  // Only a positive acknowledgement from the pinned PC proves a pairing is gone.
  // Paused, offline and older PCs cannot produce this acknowledgement.
  static Future<bool> confirmedRemoved(HostProfile profile) async {
    try {
      return await connectComputer(profile, (route) async {
        final socket = route.local
            ? await SSHSocket.connect(route.host, route.port, timeout: const Duration(seconds: 3))
            : await WebSocketSsh.connect(route.host);
        final client = SSHClient(socket, username: 'check-removed',
          onPasswordRequest: () => profile.token,
          onVerifyHostKey: (type, fingerprint) => type == 'ssh-ed25519' && utf8.decode(fingerprint) == profile.fingerprint,
          algorithms: const SSHAlgorithms(hostkey: [SSHHostkeyType.ed25519]),
          handshakeTimeout: const Duration(seconds: 6), authTimeout: const Duration(seconds: 6));
        unawaited(client.done.then<void>((_) {}, onError: (Object _) {}));
        try { await client.authenticated; return true; } finally { client.close(); }
      });
    } catch (_) { return false; }
  }
  Future<String?> currentRemoteHost() async {
    final host = (await _json('GET', 'health'))['remoteHost'];
    return validRemoteHost(host) ? host as String : null;
  }

  Future<void> _forward(Socket socket, int port) async {
    if (_closed || _sockets.length >= 16) {
      socket.destroy();
      return;
    }
    _sockets.add(socket);
    SSHForwardChannel? channel;
    StreamSubscription<List<int>>? upstream;
    StreamSubscription<List<int>>? downstream;
    final finished = Completer<void>();
    void finish() {
      if (!finished.isCompleted) finished.complete();
    }

    try {
      channel = await _client
          .forwardLocal('127.0.0.1', port)
          .timeout(const Duration(seconds: 10));
      if (_closed) return;
      final tunnel = channel;
      upstream = socket.listen(
        tunnel.sink.add,
        onError: (Object _) => finish(),
        onDone: finish,
      );
      downstream = tunnel.stream.listen(
        socket.add,
        onError: (Object _) => finish(),
        onDone: () async {
          try {
            await socket.flush();
          } catch (_) {}
          finish();
        },
      );
      unawaited(
        socket.done.then((_) => finish(), onError: (Object _) => finish()),
      );
      await finished.future;
    } catch (_) {
      // The calling HTTP request observes the closed tunnel.
    } finally {
      await upstream?.cancel();
      await downstream?.cancel();
      channel?.destroy();
      socket.destroy();
      _sockets.remove(socket);
    }
  }

  Future<HttpClientRequest> _open(
    String method,
    String route, [
    Map<String, String>? query,
  ]) async {
    if (_closed) throw const MobileException('电脑连接已断开。');
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: _server.port,
      path: '/mobile/v1/$route',
      queryParameters: query,
    );
    final request = await _http.openUrl(method, uri);
    request.followRedirects = false;
    request.persistentConnection = false;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
    return request;
  }

  Future<Json> _readJson(HttpClientResponse response) async {
    final body = await utf8.decoder.bind(response).join();
    final decoded = object(jsonDecode(body));
    if (response.statusCode >= 300 || decoded['ok'] != true) {
      throw MobileException(
        decoded['error'] as String? ?? '电脑拒绝了请求。',
        status: response.statusCode,
      );
    }
    return decoded;
  }

  Future<Json> _json(
    String method,
    String route, {
    Json? data,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final request = await _open(method, route, query);
    if (data != null) {
      final bytes = utf8.encode(jsonEncode(data));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close().timeout(
      timeout,
      onTimeout: () {
        request.abort();
        throw const MobileException('电脑响应超时，请重试。');
      },
    );
    return _readJson(response);
  }

  Future<Json> request(String type, [Json fields = const {}]) => _json(
    'POST',
    'requests',
    data: {'type': type, ...fields},
    timeout: type == 'topic.compact'
        ? const Duration(minutes: 4)
        : const Duration(seconds: 45),
  );

  Future<Json> uploadPart(
    String room,
    String id,
    String name,
    int total,
    int offset,
    List<int> bytes,
  ) async {
    final request = await _open('PUT', 'upload', {
      'conversationId': room,
      'id': id,
      'name': name,
      'total': '$total',
      'offset': '$offset',
    });
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close().timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        request.abort();
        throw const MobileException('上传暂时中断。');
      },
    );
    return _readJson(response);
  }

  Future<Json> cancelUpload(String room, String id) =>
      _json('DELETE', 'upload', query: {'conversationId': room, 'id': id});

  Future<Json> uploadStatus(String room, String id) =>
      _json('GET', 'upload', query: {'conversationId': room, 'id': id});

  Future<Json> browserTabs(String room, {String? tabId}) =>
      _json('GET', 'browser-tabs', query: {'conversationId': room, 'tabId': ?tabId});

  Future<Json> cardMusic(String room, String message, String card, {String? track}) =>
      _json('GET', 'card-music', query: {
        'conversationId': room, 'messageId': message, 'cardId': card, 'trackId': ?track,
      });

  Future<Json> stickers(String room, {String? packId}) => _json(
    'GET',
    'stickers',
    query: {'conversationId': room, 'packId': ?packId},
  );

  Stream<List<int>> speech(
    String room,
    String message, {
    String? part,
    int? pageIndex,
    Future<void>? cancel,
  }) async* {
    final request = await _open('GET', 'speech', {
      'conversationId': room,
      'messageId': message,
      'partId': ?part,
      'pageIndex': ?pageIndex?.toString(),
    });
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
    if (cancel != null) unawaited(cancel.then((_) => request.abort()));
    try {
      final response = await request.close().timeout(
        const Duration(seconds: 50),
      );
      if (response.statusCode != 200) await _readJson(response);
      yield* response.timeout(const Duration(seconds: 35));
    } finally {
      request.abort();
    }
  }

  Future<String> transcribe(String room, Uint8List bytes) async {
    final request = await _open('POST', 'speech', {'conversationId': room});
    try {
      request.contentLength = bytes.length;
      request.headers.contentType = ContentType('audio', 'wav');
      request.add(bytes);
      final response = await request.close().timeout(
        const Duration(seconds: 135),
      );
      return (await _readJson(response))['text'] as String? ?? '';
    } finally {
      request.abort();
    }
  }

  Stream<Json> events(String? conversationId, {bool inbox = false}) async* {
    final request = await _open('GET', 'events', {
      if (inbox) 'inbox': '1',
      'conversationId': ?conversationId,
    });
    final response = await request.close().timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        request.abort();
        throw const MobileException('连接电脑事件流超时。');
      },
    );
    try {
      if (response.statusCode != 200) await _readJson(response);
      await for (final line
          in response
              .timeout(const Duration(seconds: 40))
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.startsWith('data: ')) {
          yield object(jsonDecode(line.substring(6)));
        }
      }
    } finally {
      request.abort();
    }
  }

  Future<Json> upload(
    String conversationId,
    String name,
    int size,
    Stream<List<int>> bytes,
  ) async {
    if (size < 0 || size > maxUploadBytes) {
      throw const MobileException('文件超过电脑允许的上传大小。');
    }
    final request = await _open('PUT', 'files', {
      'conversationId': conversationId,
      'name': name,
    });
    request.contentLength = size;
    request.headers.contentType = ContentType.binary;
    try {
      await request.addStream(bytes.timeout(const Duration(seconds: 60)));
      final result = await request.close().timeout(const Duration(minutes: 3));
      return object((await _readJson(result))['attachment']);
    } catch (_) {
      request.abort();
      rethrow;
    }
  }

  Future<HttpClientResponse> download(
    String conversationId,
    String messageId,
    String id, {
    int offset = 0,
    bool thumbnail = false,
  }) async {
    final request = await _open('GET', 'files', {
      'conversationId': conversationId,
      'messageId': messageId,
      'id': id,
      if (thumbnail) 'thumbnail': '1',
    });
    if (offset > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
    }
    final response = await request.close().timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        request.abort();
        throw const MobileException('电脑未开始传输附件。');
      },
    );
    if (response.statusCode != 200 && response.statusCode != 206) {
      await response.drain<void>();
      throw MobileException('此附件暂时无法下载。', status: response.statusCode);
    }
    return response;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _http.close(force: true);
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    await _server.close();
    try {
      await _client.close();
    } catch (_) {}
  }
}
