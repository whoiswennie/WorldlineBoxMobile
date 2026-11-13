import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

  Future<void> save(HostProfile profile) =>
      _storage.write(key: _key, value: jsonEncode(profile.toJson()));

  Future<void> forget() => _storage.delete(key: _key);
}
