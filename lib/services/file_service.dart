import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// 文件存储服务 - 负责图片和表情的本地存储
class FileService {
  static final FileService instance = FileService._init();

  FileService._init();

  /// 获取应用文档目录
  Future<Directory> get _appDocDir async {
    // 修复点：使用 path_provider 中的 getApplicationDocumentsDirectory()
    final dir = await getApplicationDocumentsDirectory();
    return dir;
  }

  /// 获取图片存储目录
  Future<Directory> get imageDir async {
    final appDir = await _appDocDir;
    final imgDir = Directory('${appDir.path}/images');
    if (!await imgDir.exists()) {
      await imgDir.create(recursive: true);
    }
    return imgDir;
  }

  /// 获取表情存储目录
  Future<Directory> get emojiDir async {
    final appDir = await _appDocDir;
    final emDir = Directory('${appDir.path}/emojis');
    if (!await emDir.exists()) {
      await emDir.create(recursive: true);
    }
    return emDir;
  }

  /// 保存图片文件
  Future<String> saveImage(File imageFile, String fileName) async {
    try {
      final dir = await imageDir;
      final savedPath = '${dir.path}/$fileName';
      await imageFile.copy(savedPath);
      return savedPath;
    } catch (e) {
      throw Exception('保存图片失败: $e');
    }
  }

  /// 删除图片文件
  Future<void> deleteImage(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      throw Exception('删除图片失败: $e');
    }
  }

  /// 初始化表情包（将 assets/emojis 下的图片拷贝到本地存储）
  /// 这样可以快速访问表情，避免每次从 assets 读取
  ///
  /// 使用前请确保在 pubspec.yaml 中声明：
  /// flutter:
  ///   assets:
  ///     - assets/emojis/
  Future<List<String>> initEmojis() async {
    try {
      final dir = await emojiDir;
      final manifestContent = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap =
      json.decode(manifestContent) as Map<String, dynamic>;

      // 找出所有在 assets/emojis/ 路径下的图片资源
      final assetEmojiPaths = manifestMap.keys.where((key) {
        if (!key.startsWith('assets/emojis/')) return false;
        final lower = key.toLowerCase();
        return lower.endsWith('.png') ||
            lower.endsWith('.jpg') ||
            lower.endsWith('.jpeg') ||
            lower.endsWith('.webp') ||
            lower.endsWith('.gif');
      }).toList();

      final List<String> savedEmojiPaths = [];

      for (final assetPath in assetEmojiPaths) {
        final fileName = assetPath.split('/').last;
        final file = File('${dir.path}/$fileName');

        if (!await file.exists()) {
          // 将 assets 中的表情复制到本地
          final data = await rootBundle.load(assetPath);
          final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
          await file.writeAsBytes(bytes, flush: true);
        }

        savedEmojiPaths.add(file.path);
      }

      return savedEmojiPaths;
    } catch (e) {
      // 如果 AssetManifest.json 不存在或解析失败，返回空列表
      return [];
    }
  }

  /// 获取文件大小
  Future<int> getFileSize(String filePath) async {
    try {
      final file = File(filePath);
      return await file.length();
    } catch (e) {
      return 0;
    }
  }

  /// 清理缓存（删除超过30天的图片）
  Future<void> cleanOldFiles() async {
    try {
      final dir = await imageDir;
      final now = DateTime.now();

      await for (var entity in dir.list()) {
        if (entity is File) {
          final stat = await entity.stat();
          final age = now.difference(stat.modified).inDays;
          if (age > 30) {
            await entity.delete();
          }
        }
      }
    } catch (e) {
      // 清理失败不影响应用运行
    }
  }



}