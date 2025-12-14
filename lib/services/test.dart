import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
//import 'package:permission_handler/permission_handler.dart';

/// 请求存储权限
Future<bool> requestStoragePermission() async {
  // var status = await Permission.storage.request();
  // if (status.isGranted) return true;
  //
  // // Android 11+ 的特殊权限
  // if (await Permission.manageExternalStorage.isDenied) {
  //   var manageStatus = await Permission.manageExternalStorage.request();
  //   return manageStatus.isGranted;
  // }
   return false;
}
/// 导出数据库（方便调试）
Future<String> exportDb() async {
  // bool granted = await requestStoragePermission();
  // if (!granted) return "没有存储权限，无法导出数据库。";

  // 原数据库路径
  final dbPath = await getDatabasesPath();
  final source = File(join(dbPath, "chat_app.db"));

  if (!await source.exists()) {
    return "数据库不存在：${source.path}";
  }

  // 导出路径（雷电可访问的目录）
  final targetPath = "/storage/emulated/0/Download/chat_app.db";
  final target = File(targetPath);
  await target.writeAsBytes(await source.readAsBytes(), flush: true);

  return "数据库已导出到：$targetPath";
}