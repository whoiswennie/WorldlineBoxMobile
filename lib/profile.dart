import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

typedef LanEndpoint = ({String host, int port});
final _hostname = RegExp(
  r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$',
);
bool validRemoteHost(Object? host) =>
    host is String && _hostname.hasMatch(host);
bool validLanHost(Object? host) =>
    host is String &&
    InternetAddress.tryParse(host)?.type == InternetAddressType.IPv4;
bool validPort(Object? port) => port is int && port > 0 && port <= 65535;

class HostProfile {
  const HostProfile({
    required this.host,
    required this.sshPort,
    required this.username,
    required this.fingerprint,
    required this.apiPort,
    required this.token,
    this.privateKey = '',
    this.transport,
    this.passphrase = '',
    this.lanEndpoints = const [],
  });

  final String host;
  final int sshPort;
  final String username;
  final String fingerprint;
  final int apiPort;
  final String token;
  final String privateKey;
  final String? transport;
  final String passphrase;
  final List<LanEndpoint> lanEndpoints;
  String? get remoteHost => transport == 'wss' ? host : null;
  String get discoveryName =>
      'wlb-${sha256.convert(utf8.encode(fingerprint)).toString().substring(0, 24)}';
  List<LanEndpoint> get localRoutes => {
    ...lanEndpoints,
    if (transport == null) (host: host, port: sshPort),
  }.toList();

  HostProfile withRoutes({
    String? remote,
    Iterable<LanEndpoint> local = const [],
  }) {
    final lan = {...local, ...localRoutes}.take(8).toList();
    final publicHost = remote ?? remoteHost;
    return HostProfile(
      host: publicHost ?? lan.first.host,
      sshPort: publicHost == null ? lan.first.port : 443,
      transport: publicHost == null ? null : 'wss',
      lanEndpoints: lan,
      username: username,
      fingerprint: fingerprint,
      apiPort: apiPort,
      token: token,
      privateKey: privateKey,
      passphrase: passphrase,
    );
  }

  Map<String, dynamic> toJson() => {
    'host': host,
    'sshPort': sshPort,
    'username': username,
    'fingerprint': fingerprint,
    'apiPort': apiPort,
    'token': token,
    'privateKey': privateKey,
    'transport': transport,
    'passphrase': passphrase,
    'lan': [
      for (final route in lanEndpoints)
        {'host': route.host, 'port': route.port},
    ],
  };

  factory HostProfile.fromJson(Map<String, dynamic> json) => HostProfile(
    host: json['host'] as String,
    sshPort: json['sshPort'] as int,
    username: json['username'] as String,
    fingerprint: json['fingerprint'] as String,
    apiPort: json['apiPort'] as int,
    token: json['token'] as String,
    privateKey: json['privateKey'] as String? ?? '',
    transport: json['transport'] as String?,
    passphrase: json['passphrase'] as String? ?? '',
    lanEndpoints: [
      for (final item in (json['lan'] as List? ?? const []).whereType<Map>())
        if (validLanHost(item['host']) && validPort(item['port']))
          (host: item['host'] as String, port: item['port'] as int),
    ],
  );
}

class ProfileStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'worldlinebox.mobile.host.v1';

  Future<HostProfile?> read() async {
    final text = await _storage.read(key: _key);
    return text == null
        ? null
        : HostProfile.fromJson(jsonDecode(text) as Map<String, dynamic>);
  }

  Future<void> _writes = Future.value();
  Future<void> _enqueue(Future<void> Function() work) {
    final next = _writes.then((_) => work());
    _writes = next.catchError((Object _) {});
    return next;
  }

  Future<void> save(HostProfile profile) => _enqueue(
    () => _storage.write(key: _key, value: jsonEncode(profile.toJson())),
  );

  Future<void> forget() => _enqueue(() => _storage.delete(key: _key));
}
