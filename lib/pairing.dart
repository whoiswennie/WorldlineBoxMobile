import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter/services.dart';

import 'app_brand.dart';
import 'mobile_api.dart';
import 'profile.dart';

class ComputerInvitation {
  ComputerInvitation._(this.code, this.computer);
  final String code;
  final HostProfile computer;

  factory ComputerInvitation.parse(
    String text,
    String token, {
    HostProfile? saved,
  }) {
    final data = jsonDecode(text) as Json;
    final code = data['code'] as String;
    final fingerprint = data['fingerprint'] as String;
    final host = data['host'] as String;
    final port = data['sshPort'] as int;
    final transport = data['transport'];
    if (data['protocol'] != 2 ||
        data['apiPort'] != 47831 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(code) ||
        !RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$').hasMatch(fingerprint) ||
        !(transport == 'wss' && port == 443 && validRemoteHost(host) ||
            transport == null && validPort(port) && validLanHost(host))) {
      throw const FormatException();
    }
    if (saved != null && saved.fingerprint != fingerprint) {
      throw const MobileException('这个二维码属于另一台电脑。请扫描「我的电脑」上的二维码。');
    }
    final lan = object(data['lan']);
    final hints = <LanEndpoint>[
      if (validPort(lan['port']) && lan['hosts'] is List)
        for (final ip
            in (lan['hosts'] as List)
                .whereType<String>()
                .where(validLanHost)
                .take(8))
          (host: ip, port: lan['port'] as int),
      if (transport == null) (host: host, port: port),
    ];
    final profile =
        saved ??
        HostProfile(
          host: host,
          sshPort: port,
          username: 'mobile',
          fingerprint: fingerprint,
          apiPort: 47831,
          token: token,
          separatePairingCache: true,
          transport: transport as String?,
        );
    return ComputerInvitation._(
      code,
      profile.withRoutes(
        remote: transport == 'wss' ? host : null,
        local: hints,
      ),
    );
  }
}

String connectionError(Object error) {
  if (error is MobileException) return error.message;
  if (error is SocketException || error is TimeoutException) {
    return '无法连接电脑，请确认电脑在线且远程服务已开启。';
  }
  return '操作失败，请检查电脑端状态后重试。';
}

class PairingPage extends StatefulWidget {
  const PairingPage({
    super.key,
    required this.onSave,
    this.initialError,
    this.saved,
    this.known = const {},
  });
  final HostProfile? saved;
  final Map<String, HostProfile> known;
  final Future<void> Function(HostProfile, MobileApi) onSave;
  final String? initialError;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _scanner = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  String? _error;
  String? _attemptCode;
  String? _attemptToken;
  String? _lastCode;
  bool _showCamera = false;
  bool _busy = false;

  List<Json> _nearby = [];
  final _attempts = <String, HostProfile>{};
  Completer<void>? _cancelEnrollment;
  Timer? _refresh;
  bool _searching = false;
  String? _networkStatus;
  String? _approval;

  @override
  void initState() {
    super.initState();
    if (widget.saved == null) {
      unawaited(_discover());
      _refresh = Timer.periodic(const Duration(seconds: 10), (_) {
        if (mounted &&
            ModalRoute.of(context)?.isCurrent == true &&
            WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed) {
          unawaited(_discover());
        }
      });
    }
  }

  Future<void> _discover() async {
    if (_searching || _busy || _showCamera) return;
    setState(() => _searching = true);
    try {
      final found = await const MethodChannel(
        'worldlinebox/local-computers',
      ).invokeListMethod<dynamic>('nearby').timeout(const Duration(seconds: 6));
      final identities = <String>{};
      final hosts = <Json>[
        for (final entry in (found ?? []).whereType<Map>())
          if (validLanHost(entry['host']) &&
              validPort(entry['port']) &&
              entry['fingerprint'] is String &&
              RegExp(
                r'^SHA256:[A-Za-z0-9+/]{43}$',
              ).hasMatch(entry['fingerprint']) &&
              entry['name'] is String &&
              (entry['name'] as String).trim().isNotEmpty &&
              identities.add(entry['fingerprint'] as String))
            Map<String, dynamic>.from(entry),
      ]..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
      if (mounted) {
        setState(() {
          _nearby = hosts;
          _networkStatus = found == null
              ? '连接 Wi-Fi 后可发现附近电脑。'
              : '还没有发现电脑。请确认电脑已打开 WorldlineBox，并连接同一局域网。';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _networkStatus = '暂时无法搜索局域网，请刷新重试。');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  String _newToken() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> _connectNearby(Json host) async {
    if (_busy) return;
    final fingerprint = host['fingerprint'] as String;
    final route = (host: host['host'] as String, port: host['port'] as int);
    setState(() {
      _busy = true;
      _error = null;
      _lastCode = null;
    });
    MobileApi? api;
    try {
      final known = (widget.known[fingerprint] ?? _attempts[fingerprint])
          ?.withRoutes(local: [route]);
      if (known != null && !await MobileApi.confirmedRemoved(known)) {
        api = await MobileApi.connect(known, localOnly: true);
      } else {
        final token = _newToken();
        final profile = HostProfile(
          host: route.host,
          sshPort: route.port,
          apiPort: 47831,
          username: 'mobile',
          fingerprint: fingerprint,
          name: host['name'],
          token: token,
          separatePairingCache: true,
        );
        final code = sha256
            .convert(utf8.encode(fingerprint + token))
            .toString()
            .substring(0, 10)
            .toUpperCase();
        if (!mounted) return;
        setState(() => _approval = '请在电脑上核对连接码 $code，并点击「同意连接」。');
        final model = await const MethodChannel(
          'worldlinebox/messages',
        ).invokeMethod<String>('deviceName');
        if (!mounted) return;
        _attempts[fingerprint] = profile;
        final cancel = _cancelEnrollment = Completer<void>();
        api = await MobileApi.pairNearby(
          profile,
          model ?? 'Android 手机',
          cancel.future,
        );
      }
      if (mounted) {
        await widget.onSave(api.profile, api);
        api = null;
      }
    } catch (error) {
      if (mounted) setState(() => _error = connectionError(error));
    } finally {
      if (_cancelEnrollment?.isCompleted == false) {
        _cancelEnrollment!.complete();
      }
      _cancelEnrollment = null;
      await api?.close();
      if (mounted) {
        setState(() {
          _approval = null;
          _busy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    if (_cancelEnrollment?.isCompleted == false) _cancelEnrollment!.complete();
    _refresh?.cancel();
    unawaited(_scanner.dispose());
    super.dispose();
  }

  void _detected(BarcodeCapture capture) {
    if (_busy) return;
    for (final barcode in capture.barcodes) {
      final text = barcode.rawValue;
      if (text != null) {
        unawaited(_pair(text));
        return;
      }
    }
  }

  Future<void> _fromImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
      );
      if (!mounted || result == null || result.files.single.path == null) {
        return;
      }
      final capture = await _scanner.analyzeImage(
        result.files.single.path!,
        formats: [BarcodeFormat.qrCode],
      );
      if (!mounted) return;
      if (capture == null || capture.barcodes.isEmpty) {
        setState(() => _error = '这张图片里没有找到配对二维码。');
        return;
      }
      _detected(capture);
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取二维码图片。');
    }
  }

  Future<void> _pair(String text) async {
    if (_busy) return;
    late ComputerInvitation invitation;
    HostProfile? saved;
    try {
      if (_attemptCode != text) {
        _attemptCode = text;
        _attemptToken = _newToken();
      }
      saved =
          widget.saved ?? widget.known[object(jsonDecode(text))['fingerprint']];
      invitation = ComputerInvitation.parse(text, _attemptToken!, saved: saved);
    } catch (error) {
      setState(
        () => _error = error is MobileException
            ? error.message
            : '请扫描电脑「设置 → 手机连接」里的二维码。',
      );
      return;
    }
    _lastCode = text;
    setState(() {
      _busy = true;
      _error = null;
    });
    MobileApi? unclaimed;
    try {
      if (saved != null &&
          await MobileApi.confirmedRemoved(invitation.computer)) {
        invitation = ComputerInvitation.parse(text, _attemptToken!);
        saved = null;
      }
      final String? model = await const MethodChannel(
        'worldlinebox/messages',
      ).invokeMethod<String>('deviceName').catchError((_) => null);
      final api = unclaimed = await MobileApi.connect(
        invitation.computer,
        pairingCode: saved == null ? invitation.code : null,
        deviceName: model ?? 'Android 手机',
      );
      if (mounted) {
        await widget.onSave(api.profile, api);
        unclaimed = null;
      }
    } catch (error) {
      if (mounted) setState(() => _error = connectionError(error));
    } finally {
      await unclaimed?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const BrandTitle()),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(14),
                    child: Icon(Icons.devices_rounded, size: 32),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                widget.saved == null ? '连接电脑' : '更新连接地址',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.saved == null
                    ? '选择同一局域网的电脑。首次连接需要电脑同意，以后会自动重连。'
                    : '扫描这台电脑的新二维码，更新远程地址并保留已有配对。',
              ),
              const SizedBox(height: 24),
              if (widget.saved == null && !_showCamera) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '附近的电脑',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新',
                      onPressed: _busy || _searching ? null : _discover,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                if (_nearby.isEmpty)
                  Text(_searching ? '正在搜索局域网…' : _networkStatus ?? ''),
                for (final host in _nearby)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.computer),
                      title: Text(host['name']),
                      subtitle: Text(host['host']),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy ? null : () => _connectNearby(host),
                    ),
                  ),
                if (_approval != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(_approval!),
                  ),
                const SizedBox(height: 20),
              ],
              if (_showCamera) ...[
                AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: MobileScanner(
                      controller: _scanner,
                      onDetect: _detected,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (_busy) const LinearProgressIndicator(),
              if (_error ?? widget.initialError case final String error)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 12),
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (!_showCamera)
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() => _showCamera = true);
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              unawaited(
                                _scanner.start().catchError((Object _) {
                                  if (mounted) {
                                    setState(
                                      () => _error = '请允许相机权限，或从相册选择二维码。',
                                    );
                                  }
                                }),
                              );
                            }
                          });
                        },
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('扫描二维码'),
                ),
              if (_error != null && _lastCode != null)
                FilledButton(
                  onPressed: _busy ? null : () => _pair(_lastCode!),
                  child: const Text('重新连接'),
                ),
              TextButton(
                onPressed: _busy ? null : _fromImage,
                child: const Text('从相册选择二维码'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
