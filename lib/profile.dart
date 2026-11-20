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
    this.name = '',
    this.separatePairingCache = false,
    this.privateKey = '',
    this.transport,
    this.passphrase = '',
    this.lanEndpoints = const [],
  });

  final String name;
  final bool separatePairingCache;
  String get cacheIdentity => separatePairingCache
      ? discoveryName + sha256.convert(utf8.encode(token)).toString()
      : fingerprint;
  String get displayName => name.isNotEmpty
      ? name
      : localRoutes.firstOrNull?.host ?? remoteHost ?? '已配对电脑';
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
    String? computerName,
    bool clearRemote = false,
    Iterable<LanEndpoint> local = const [],
  }) {
    final lan = {...local, ...localRoutes}.take(8).toList();
    final publicHost = clearRemote ? null : remote ?? remoteHost;
    return HostProfile(
      name: computerName?.trim().isNotEmpty == true
          ? computerName!.trim()
          : name,
      host: publicHost ?? lan.firstOrNull?.host ?? '',
      sshPort: publicHost == null ? lan.firstOrNull?.port ?? 0 : 443,
      transport: publicHost != null
          ? 'wss'
          : lan.isEmpty
          ? 'discovery'
          : null,
      lanEndpoints: lan,
      separatePairingCache: separatePairingCache,
      username: username,
      fingerprint: fingerprint,
      apiPort: apiPort,
      token: token,
      privateKey: privateKey,
      passphrase: passphrase,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'separatePairingCache': separatePairingCache,
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
    separatePairingCache: json['separatePairingCache'] == true,
    name: json['name'] as String? ?? '',
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

class HostDirectory {
  HostDirectory(this.profiles, this.active);
  final Map<String, HostProfile> profiles;
  String? active;
  HostProfile? get current => profiles[active];
}

class ProfileStore {
  static const _storage = FlutterSecureStorage();
  static const _legacy = 'worldlinebox.mobile.host.v1';
  static const _key = 'worldlinebox.mobile.computers.v2';
  Future<void> _writes = Future.value();

  Future<HostDirectory> _read() async {
    final raw = await _storage.read(key: _key);
    if (raw != null) {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final all = (data['profiles'] as List).cast<Map<String, dynamic>>().map(
        HostProfile.fromJson,
      );
      return HostDirectory({
        for (final p in all) p.fingerprint: p,
      }, data['active'] as String?);
    }
    final old = await _storage.read(key: _legacy);
    if (old == null) return HostDirectory({}, null);
    final profile = HostProfile.fromJson(jsonDecode(old));
    final migrated = HostDirectory({
      profile.fingerprint: profile,
    }, profile.fingerprint);
    await _write(migrated);
    await _storage.delete(key: _legacy);
    return migrated;
  }

  Future<void> _write(HostDirectory records) => _storage.write(
    key: _key,
    value: jsonEncode({
      'active': records.active,
      'profiles': records.profiles.values.map((p) => p.toJson()).toList(),
    }),
  );

  Future<HostDirectory> _run([void Function(HostDirectory)? edit]) {
    final result = _writes.then((_) async {
      final records = await _read();
      if (edit != null) {
        edit(records);
        await _write(records);
      }
      return records;
    });
    _writes = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<HostDirectory> read() => _run();
  Future<HostDirectory> pair(HostProfile p) => _run((d) {
    d.profiles[p.fingerprint] = p;
    d.active = p.fingerprint;
  });
  Future<HostDirectory> select(String id) => _run((d) {
    if (!d.profiles.containsKey(id)) throw StateError('这台电脑的配对已移除。');
    d.active = id;
  });
  Future<void> update(HostProfile p) async {
    await _run((d) {
      if (d.profiles[p.fingerprint]?.token == p.token) {
        d.profiles[p.fingerprint] = p;
      }
    });
  }

  Future<HostDirectory> forget(String id) => _run((d) {
    d.profiles.remove(id);
    if (d.active == id) d.active = d.profiles.keys.firstOrNull;
  });

  Future<HostDirectory> clean(Map<HostProfile, HostProfile?> changes) =>
      _run((d) {
        for (final entry in changes.entries) {
          final old = entry.key;
          final current = d.profiles[old.fingerprint];
          if (current == null ||
              current.token != old.token ||
              current.remoteHost != old.remoteHost) {
            continue;
          }
          if (entry.value == null) {
            d.profiles.remove(old.fingerprint);
          } else {
            d.profiles[old.fingerprint] = current.withRoutes(
              remote: entry.value!.remoteHost,
              clearRemote: entry.value!.remoteHost == null,
              local: entry.value!.localRoutes,
            );
          }
        }
        if (!d.profiles.containsKey(d.active)) {
          d.active = d.profiles.keys.firstOrNull;
        }
      });
}
