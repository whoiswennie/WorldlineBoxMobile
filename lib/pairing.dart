import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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
  });
  final HostProfile? saved;
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

  @override
  void dispose() {
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
    late final ComputerInvitation invitation;
    try {
      if (_attemptCode != text) {
        _attemptCode = text;
        final random = Random.secure();
        _attemptToken = List.generate(
          32,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
      }
      invitation = ComputerInvitation.parse(
        text,
        _attemptToken!,
        saved: widget.saved,
      );
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
      final api = unclaimed = await MobileApi.connect(
        invitation.computer,
        pairingCode: widget.saved == null ? invitation.code : null,
        deviceName: 'Android 手机',
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
                    ? '打开电脑「设置 → 手机连接」并扫码。下次在同一局域网，手机会自动连接。'
                    : '扫描这台电脑的新二维码，更新远程地址并保留已有配对。',
              ),
              const SizedBox(height: 24),
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
