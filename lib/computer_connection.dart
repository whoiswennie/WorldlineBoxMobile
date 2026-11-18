import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'profile.dart';

typedef ComputerRoute = ({String host, int port, bool local});

Future<List<LanEndpoint>?> discoverComputer(HostProfile profile) async {
  if (!Platform.isAndroid) return [];
  try {
    final found = await const MethodChannel('worldlinebox/local-computers')
        .invokeListMethod<dynamic>('find', profile.discoveryName)
        .timeout(const Duration(seconds: 3));
    if (found == null) return null; // No active LAN.
    return [
      for (final item in found.whereType<Map>())
        if (validLanHost(item['host']) && validPort(item['port']))
          (host: item['host'] as String, port: item['port'] as int),
    ];
  } on Exception {
    return []; // Cached addresses and the public route can still work.
  }
}

Future<T> connectComputer<T>(
  HostProfile profile,
  Future<T> Function(ComputerRoute) dial, {
  bool localOnly = false,
  Future<List<LanEndpoint>?> Function(HostProfile) discover = discoverComputer,
}) async {
  final found = await discover(profile);
  Object? lastError;
  if (found != null) {
    for (final address in {...found, ...profile.localRoutes}) {
      try {
        return await dial((
          host: address.host,
          port: address.port,
          local: true,
        ));
      } catch (error) {
        lastError = error;
      }
    }
  }
  final remote = profile.remoteHost;
  if (!localOnly && remote != null) {
    return dial((host: remote, port: 443, local: false));
  }
  throw lastError ??
      const SocketException('No available connection to the paired computer');
}
