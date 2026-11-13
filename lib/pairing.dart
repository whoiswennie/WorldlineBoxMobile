import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'mobile_api.dart';
import 'profile.dart';

final _publicHostname = RegExp(
  r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+'
  r'[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$',
);

String connectionError(Object error) {
  if (error is MobileException) return error.message;
  if (error is SocketException || error is TimeoutException) {
    return '无法连接电脑，请确认电脑在线且远程服务已开启。';
  }
  return '操作失败，请检查电脑端状态后重试。';
}

class PairingPage extends StatefulWidget {
  const PairingPage({super.key, required this.onSave, this.initialError});
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
    late final Json details;
    late final String code;
    late final String host;
    late final int port;
    late final String fingerprint;
    try {
      details = jsonDecode(text) as Json;
      code = details['code'] as String;
      host = details['host'] as String;
      port = details['sshPort'] as int;
      fingerprint = details['fingerprint'] as String;
      final transport = details['transport'];
      if (details['protocol'] != 2 ||
          details['apiPort'] != 47831 ||
          (transport != null && transport != 'wss') ||
          (transport == 'wss' ? port != 443 : port != 47832) ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(code) ||
          !RegExp(r'^SHA256:[A-Za-z0-9+/]{43}$').hasMatch(fingerprint) ||
          (transport == 'wss'
              ? !_publicHostname.hasMatch(host)
              : InternetAddress.tryParse(host)?.type !=
                    InternetAddressType.IPv4)) {
        throw const FormatException();
      }
    } catch (_) {
      setState(() => _error = '请扫描世界线盒子「远程连接」里显示的二维码。');
      return;
    }
    _lastCode = text;
    if (_attemptCode != code) {
      _attemptCode = code;
      final random = Random.secure();
      _attemptToken = List.generate(
        32,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
    }
    final profile = HostProfile(
      host: host,
      sshPort: port,
      username: 'mobile',
      fingerprint: fingerprint,
      apiPort: 47831,
      token: _attemptToken!,
      transport: details['transport'] as String?,
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    MobileApi? unclaimed;
    try {
      final api = unclaimed = await MobileApi.connect(
        profile,
        pairingCode: code,
        deviceName: 'Android 手机',
      );
      if (mounted) {
        await widget.onSave(profile, api);
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
    appBar: AppBar(title: const Text('世界线盒子')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                '连接电脑',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              const Text('在电脑上打开「设置 → 远程连接」，显示配对二维码。'),
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
