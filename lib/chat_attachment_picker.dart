import 'dart:io';

import 'package:file_picker/file_picker.dart';
// Use the same Material widgets as the composer.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

import 'mobile_api.dart';

enum ChatAttachmentSource {
  gallery('手机相册', Icons.photo_library_outlined),
  videos('本地视频', Icons.video_library_outlined),
  file('手机文件', Icons.folder_outlined),
  photo('拍照', Icons.photo_camera_outlined),
  movie('录像', Icons.videocam_outlined);

  const ChatAttachmentSource(this.label, this.icon);
  final String label;
  final IconData icon;

  bool get isCamera => this == photo || this == movie;
}

typedef PickedAttachment = ({String name, String? path});

Future<ChatAttachmentSource?> chooseAttachmentSource(BuildContext context) =>
    showModalBottomSheet<ChatAttachmentSource>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('添加附件', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) => Wrap(
                  runSpacing: 8,
                  children: [
                    for (final source in ChatAttachmentSource.values)
                      SizedBox(
                        width: constraints.maxWidth / 3,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => Navigator.pop(context, source),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Column(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(13),
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Icon(source.icon),
                                ),
                                const SizedBox(height: 6),
                                Text(source.label),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

String _albumLabel(AssetPathEntity path, bool videosOnly) {
  if (path.isAll) return videosOnly ? '所有视频' : '图片和视频';
  return switch (path.name.toLowerCase()) {
    'camera' => '相机',
    'screenshots' => '截屏',
    _ => path.name,
  };
}

Future<List<PickedAttachment>> pickChatFiles(
  BuildContext context,
  ChatAttachmentSource source,
  int limit,
) async {
  if (source == ChatAttachmentSource.file) {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: limit > 1,
    );
    return [
      for (final file in result?.files ?? <PlatformFile>[])
        (name: file.name, path: file.path),
    ];
  }
  final videosOnly = source == ChatAttachmentSource.videos;
  final List<AssetEntity>? assets;
  try {
    assets = await AssetPicker.pickAssets(
      context,
      pickerConfig: AssetPickerConfig(
        maxAssets: limit,
        requestType: videosOnly ? RequestType.video : RequestType.common,
        textDelegate: const AssetPickerTextDelegate(),
        pathNameBuilder: (path) => _albumLabel(path, videosOnly),
        themeColor: const Color(0xffb8a4ed),
      ),
    );
  } on StateError catch (error) {
    if (!error.message.contains('Permission state')) rethrow;
    throw const MobileException('请在手机设置中允许访问照片和视频，再打开相册。');
  }
  final files = <PickedAttachment>[];
  for (final asset in assets ?? <AssetEntity>[]) {
    String? name = asset.title;
    File? file;
    try {
      if (name == null || name.isEmpty) name = await asset.titleAsync;
      file = await asset.file;
    } on PlatformException {
      // The user can still attach other items if one was removed from the album.
    }
    files.add((
      name: (name?.isNotEmpty ?? false)
          ? name!
          : file?.uri.pathSegments.last ?? '媒体文件',
      path: file?.path,
    ));
  }
  return files;
}

/// Android can recreate the chat process while the system camera is in front.
/// Its plugin keeps one global result, so only the initiating request may claim it.
class ChatCamera {
  static Future<File> _owner() async => File(
    '${(await getApplicationSupportDirectory()).path}/chat-camera-request',
  );

  static Future<XFile?> capture(String id, bool video) async {
    await (await _owner()).writeAsString(id, flush: true);
    final picker = ImagePicker();
    return video
        ? picker.pickVideo(source: ImageSource.camera)
        : picker.pickImage(
            source: ImageSource.camera,
            requestFullMetadata: false,
          );
  }

  static Future<XFile?> recover(String id) async {
    final owner = await _owner();
    if (!await owner.exists() || await owner.readAsString() != id) return null;
    final result = await ImagePicker().retrieveLostData();
    if (result.exception case final error?) throw error;
    return result.files?.firstOrNull;
  }

  static String name(XFile file, bool video, int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp)
        .toIso8601String()
        .replaceFirst('T', '_')
        .replaceAll(':', '-')
        .split('.')
        .first;
    final extension = RegExp(
      r'\.([a-zA-Z0-9]{1,8})$',
    ).firstMatch(file.name)?.group(1);
    return '${video ? "录像" : "照片"}_$date.${extension ?? (video ? "mp4" : "jpg")}';
  }

  static Future<void> discardTempFile(String path) async {
    try {
      final cache = await getTemporaryDirectory();
      final file = File(path);
      if (file.absolute.path.startsWith(
            '${cache.absolute.path}${Platform.pathSeparator}',
          ) &&
          await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Android may already have reclaimed the camera cache.
    }
  }
}
