import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import 'dart:io'; // 添加: 提供 File
import 'chat_service.dart';
import 'database_service.dart';
import 'package:http/http.dart' as http; // NEW: HTTP 客户端
import 'package:sqflite/sqflite.dart';

/// 本地登录服务
/// - 提供登录/登出
/// - 将当前登录用户持久化到 SharedPreferences
/// - 仅用于演示，不包含服务端接口与加密
class AuthService extends ChangeNotifier {

  static final AuthService instance = AuthService._internal();
  AuthService._internal(); // 私有构造
  factory AuthService() => instance;


  static const _kUserIdKey = 'auth.userId';
  static const _kUserNameKey = 'auth.userName';
  static const _kAvatarKey = 'auth.avatar';

  /// 示例 API 基础 URL
  static const String _apiBaseUrl = 'http://127.0.0.1:8080';
  String get apiBaseUrl => _apiBaseUrl;


  User? _currentUser;
  User? get currentUser => _currentUser;
  bool get isAuthenticated => _currentUser != null;
  String? get token => _currentUser?.token;
  bool get hasAvatar => (_currentUser?.avatar?.isNotEmpty ?? false);

  Future<User?> getUserById(String userId) async {
    return await DatabaseService.instance.getUserById(userId);
  }


  /// 初始化：从本地加载会话
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_kUserIdKey);
    final name = prefs.getString(_kUserNameKey);
    final avatar = prefs.getString(_kAvatarKey);

    if (id != null && name != null) {
      _currentUser = User(id: id, name: name, avatar: avatar);
      notifyListeners();
    }
  }

  /// 本地模式 -- 废弃
  /// 登录：用户名即 userId（示例），密码校验通过后写入会话
  // Future<void> login({
  //   required String username,
  //   required String password,
  // }) async
  // {
  //
  //   final db = await DatabaseService.instance.database;
  //
  //   // 查询数据库中是否存在该用户，同时校验密码
  //   final result = await db.query(
  //     'users',
  //     where: 'id = ? AND passwordHash = ?',
  //     whereArgs: [username, password],
  //   );
  //
  //   if (result.isEmpty) {
  //     // 用户不存在或者密码错误
  //     // 先检查用户名是否存在，用于给出更精确的错误信息
  //     final userExists = await db.query(
  //       'users',
  //       where: 'id = ?',
  //       whereArgs: [username],
  //     );
  //
  //     if (userExists.isEmpty) {
  //       throw Exception('用户不存在！');
  //     } else {
  //       throw Exception('密码错误！');
  //     }
  //   }
  //
  //   // 查询到的用户信息，第一条（也是唯一一条）
  //   final record = result.first;
  //
  //   // 登录成功，构造当前用户
  //   _currentUser = User(
  //     id: record['id'] as String,
  //     name: record['name'] as String? ?? username,
  //     avatar: record['avatar'] as String?,
  //   );
  //
  //   notifyListeners();
  //   debugPrint('login end');
  // }

  /// 注册用户 废弃-本地数据库
  // Future<void> registerUser({
  //   required String uid,
  //   required String name,
  //   required String password,
  // }) async {
  //   final db = await DatabaseService.instance.database;
  //
  //   // 检查 uid 是否存在
  //   final existing = await db.query(
  //     'users',
  //     where: 'id = ?',
  //     whereArgs: [uid],
  //     limit: 1,
  //   );
  //
  //   if (existing.isNotEmpty) {
  //     throw Exception('该 UID 已存在');
  //   }
  //
  //   // 生成密码哈希,方便测试暂不使用
  //   final passwordHash = sha256.convert(utf8.encode(password)).toString();
  //
  //   // 写入用户数据
  //   await db.insert(
  //     'users',
  //     {
  //       'id': uid,
  //       'name': name,
  //       'avatar': null,
  //       'passwordHash': password,
  //     },
  //     conflictAlgorithm: ConflictAlgorithm.abort,
  //   );
  // }

 ///客户端——服务器模式
  /// 注册用户：调用服务器 API 注册新用户
  Future<void> registerUser({
    required String uid,
    required String name,
    required String password,
  }) async
  {
    final uri = Uri.parse('$_apiBaseUrl/api/register');
    debugPrint('[register] start -> $uri');
    debugPrint('[register] payload: uid=$uid, name=$name');

    http.Response resp;
    try {
      resp = await http
          .post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'uid': uid,
          'name': name,
          'password': password, // 服务器负责哈希
        }),
      )
          .timeout(const Duration(seconds: 8));
      debugPrint('[register] http status=${resp.statusCode}');
      debugPrint('[register] body=${resp.body}');
    } on TimeoutException catch (_) {
      debugPrint('[register] timeout');
      throw Exception('连接超时，请检查服务器是否运行及网络是否可达');
    } catch (e) {
      debugPrint('[register] network error: $e');
      throw Exception('无法连接服务器：$e');
    }

    if (resp.statusCode == 200) {
      try {
        final map = jsonDecode(resp.body) as Map<String, dynamic>;
        final code = map['code'] as int? ?? 0;
        final msg = map['message'] as String? ?? '';
        debugPrint('[register] parsed code=$code, msg=$msg');
        if (code != 0) {
          throw Exception(msg.isEmpty ? '注册失败（code=$code）' : msg);
        }
      } catch (e) {
        debugPrint('[register] parse error: $e');
        throw Exception('注册失败，响应解析错误：$e');
      }
      debugPrint('[register] success');
      return;
    }

    if (resp.statusCode == 409) {
      debugPrint('[register] uid exists');
      throw Exception('该 UID 已存在');
    }

    debugPrint('[register] unexpected status ${resp.statusCode}');
    throw Exception('注册失败，服务器返回 ${resp.statusCode}');
  }

  /// 登录：调用服务器 API 验证用户身份，成功后写入会话
  Future<void> login({
    required String username,
    required String password,
  }) async
  {
    final uri = Uri.parse('$_apiBaseUrl/api/login');
    debugPrint('[login] start -> $uri');
    debugPrint('[login] payload: uid=$username');

    http.Response resp;
    try {
      resp = await http
          .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'uid': username, 'password': password}),
      )
          .timeout(const Duration(seconds: 8));
      debugPrint('[login] http status=${resp.statusCode}');
      debugPrint('[login] body=${resp.body}');
    } on TimeoutException {
      debugPrint('[login] timeout');
      throw Exception('登录超时，请检查服务器是否运行及网络是否可达');
    } catch (e) {
      debugPrint('[login] network error: $e');
      throw Exception('无法连接服务器：$e');
    }

    if (resp.statusCode == 200) {
      try {
        final map = jsonDecode(resp.body) as Map<String, dynamic>;
        final code = map['code'] as int? ?? 0;
        final msg = map['message'] as String? ?? '';
        debugPrint('[login] parsed code=$code, msg=$msg');

        if (code != 0) {
          throw Exception(msg.isEmpty ? '登录失败（code=$code）' : msg);
        }

        final data = (map['data'] ?? {}) as Map<String, dynamic>;
        final token = data['token'] as String?;
        if (token == null || token.isEmpty) throw Exception('登录失败：缺少 token');

        _currentUser = User(
          id: data['uid'] as String? ?? username,
          name: data['name'] as String? ?? username,
          avatar: data['avatar'] as String?,
          token: token, // 给 User 增加 token 字段
        );

        final db = await DatabaseService.instance.database;
        await db.insert(
          'users',
          {
            'id': _currentUser!.id,
            'name': _currentUser!.name,
            'avatar': _currentUser!.avatar,
          },
          conflictAlgorithm: ConflictAlgorithm.replace, // 已存在则更新
        );


        //登录成功后同步联系人
        try {
          await _syncFromServer(); // 先同步再读
        } catch (e) {
          debugPrint('联系人同步失败: $e');
          // 可选择忽略，让用户仍然进入主界面
        }
        // 可选：持久化 token
        // await prefs.setString('auth_token', token);

        notifyListeners();


        debugPrint('[login] success');
        return;
      } catch (e) {
        debugPrint('[login] parse error: $e');
        throw Exception('登录失败，响应解析错误：$e');
      }
    }

    if (resp.statusCode == 401) {
      throw Exception('密码错误！');
    }
    if (resp.statusCode == 404) {
      throw Exception('用户不存在！');
    }
    if (resp.statusCode == 400) {
      throw Exception('请求格式错误，请重试');
    }

    debugPrint('[login] unexpected status ${resp.statusCode}');
    throw Exception('登录失败，服务器返回 ${resp.statusCode}');
  }

  Future<http.Response> authedPost(String path, Map<String, dynamic> body) async {
    final token = _currentUser?.token;
    if (token == null) throw Exception('未登录');

    final uri = Uri.parse('$_apiBaseUrl$path');
    return http
        .post(uri,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode(body))
        .timeout(const Duration(seconds: 8));
  }


/// 同步函数
  Future<void> _syncFromServer() async {
    final user = currentUser;
    final token = user?.token?.trim();
    if (user == null || token == null || token.isEmpty) {
      throw Exception('未登录或缺少 token');
    }

    debugPrint('[sync] token="$token"');

    // 同步联系人
    final uri = Uri.parse('$_apiBaseUrl/api/contacts');
    final resp = await http
        .get(uri, headers: {
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
    })
        .timeout(const Duration(seconds: 8));

    if (resp.statusCode == 401) {
      throw Exception('获取联系人失败：401（token 无效或已过期）');
    }
    if (resp.statusCode != 200) {
      throw Exception('获取联系人失败：${resp.statusCode}');
    }

    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final code = map['code'] as int? ?? -1;
    final msg = map['message'] as String? ?? '获取联系人失败';
    if (code != 0) throw Exception(msg);

    final data = (map['data'] ?? []) as List<dynamic>;
    final contacts = data.map((e) {
      final m = e as Map<String, dynamic>;
      return {
        'contactId1': m['contactId1'] as String? ?? '',
        'contactId2': m['contactId2'] as String? ?? '',
        'status': m['status'] as String? ?? 'accepted',
        'createdAt':
        m['createdAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      };
    }).toList();

    final dbService = DatabaseService.instance;
    await dbService.overwriteContacts(contacts);

    debugPrint('同步联系人完成，共 ${contacts.length} 条');


    //  同步服务器聊天会话，覆盖写入本地 chats 表
    final chatsUri = Uri.parse('${_apiBaseUrl}/api/chats');
    final chatsResp = await http
        .get(chatsUri, headers: {'Authorization': 'Bearer ${user.token}'})
        .timeout(const Duration(seconds: 8));

    if (chatsResp.statusCode != 200) {
      throw Exception('获取 chats 失败：${chatsResp.statusCode}');
    }

    final chatsMap = jsonDecode(chatsResp.body) as Map<String, dynamic>;
    final chatsCode = chatsMap['code'] as int? ?? -1;
    final chatsMsg = chatsMap['message'] as String? ?? '获取 chats 失败';
    if (chatsCode != 0) throw Exception(chatsMsg);

    final chatsData = (chatsMap['data'] ?? []) as List<dynamic>;
    final chats = chatsData.map((e) {
      final m = e as Map<String, dynamic>;
      // 根据服务器返回字段自行调整下面的字段名和默认值
      return {
        'id': (m['chatId'] as String?) ?? (m['id'] as String?) ?? '',
        'name': (m['title'] as String?) ?? (m['name'] as String?) ?? '',
        'participantIds': jsonEncode(m['participantIds'] ?? m['participants'] ?? []),
        'lastMessage': (m['lastMessage'] as String?) ?? '',
        'lastMessageTime': (m['lastAt'] as int?) ?? (m['lastMessageTime'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
        'unreadCount': (m['unreadCount'] as int?) ?? 0,
      };
    }).toList();

    // 在覆盖写入前缓存已有的 lastMessageTime
    final Map<String, int> lastTimeCache = {};
    for (final c in chats) {
      final chatId = c['id'] as String;
      if (chatId.isEmpty) continue;
      final t = await dbService.getLastMessageTime(chatId);
      if (t != null) lastTimeCache[chatId] = t;
      debugPrint('${chatId}上一条信息最后时间为 ${t} ');
    }


    await dbService.overwriteChats(chats);
    debugPrint('同步聊天列表完成，共 ${chats.length} 条');

    // === 新增：按 chatId 同步缺失消息，追加到本地 ===
// 1) 服务端支持增量：GET /api/messages?chatId=xxx&since=timestamp&limit=200
// 2) 本地可查到某个 chat 最新消息时间：dbService.getLastMessageTime(chatId)
// 3) 本地插入：dbService.insertMessages(List<Map<String,dynamic>> msgs)
    for (final c in chats) {
      final chatId = c['id'] as String;
      if (chatId.isEmpty) continue;

      int since = lastTimeCache[chatId] ?? 0;
      bool hasMore = true;


      while (hasMore) {
        final msgUri = Uri.parse(
            '${_apiBaseUrl}/api/messages?chatId=$chatId&since=$since&limit=200');
        final msgResp = await http
            .get(msgUri, headers: {'Authorization': 'Bearer ${user.token}'})
            .timeout(const Duration(seconds: 8));

        if (msgResp.statusCode != 200) {
          debugPrint('获取消息失败 chat=$chatId code=${msgResp.statusCode}');
          break;
        }

        final msgMap = jsonDecode(msgResp.body) as Map<String, dynamic>;
        final code = msgMap['code'] as int? ?? -1;
        if (code != 0) {
          debugPrint('获取消息失败 chat=$chatId msg=${msgMap['message']}');
          break;
        }

        final data = (msgMap['data'] ?? []) as List<dynamic>;
        debugPrint('[syncMessages] chat=$chatId got=${data.length}');
        if (data.isEmpty) {
          hasMore = false; // 或直接 break;
          break;
        }

        final msgs = data.map((e) {
          final m = e as Map<String, dynamic>;
          return {
            'id': (m['id'] as String?) ?? '',
            'chatId': chatId,
            'senderId': m['senderId'] as String? ?? '',
            'senderName': m['senderName'] as String? ?? '',
            'type': m['type'] ?? 0,
            'content': m['content'] ?? '',
            // 表里时间字段名是 timestamp
            'timestamp': m['timestamp'] ?? m['createdAt'] ?? 0,
            // 表里读状态字段名是 isRead，int
            'isRead': m['isRead'] ?? 0,
          };
        }).toList();

        debugPrint('[syncMessages] will insert ${msgs.length} to DB');
        await dbService.insertMessages(msgs);

        // 更新 since 为本批次最大时间戳
        since = msgs
            .map((m) => m['createdAt'] as int? ?? 0)
            .fold<int>(since, (p, e) => e > p ? e : p);

        // 若返回条数少于 limit，认为没有更多
        hasMore = data.length >= 200;
      }
      debugPrint('同步消息完成 chat=$chatId since=$since');
    }



    // === 同步本地 users 表：以服务器为准（存在即更新，不存在即插入） ===
    final db = await dbService.database;

// 1) 收集所有 contactId
    final Set<String> ids = {};
    for (final c in contacts) {
      final id1 = c['contactId1'] as String? ?? '';
      final id2 = c['contactId2'] as String? ?? '';
      if (id1.isNotEmpty) ids.add(id1);
      if (id2.isNotEmpty) ids.add(id2);
    }

    if (ids.isEmpty) return;

// 2) 批量请求服务器（全部 ids）
    final idsParam = ids.join(',');
    final batchUri = Uri.parse('${_apiBaseUrl}/api/users/batch?ids=$idsParam');
    debugPrint('[sync] fetch users batch: $batchUri');

    http.Response userResp;
    try {
      userResp = await http
          .get(batchUri, headers: {'Authorization': 'Bearer ${user.token}'})
          .timeout(const Duration(seconds: 8));
      debugPrint('[sync] batch status=${userResp.statusCode}');
    } catch (e) {
      debugPrint('[sync] batch request error: $e');
      return;
    }

    if (userResp.statusCode != 200) {
      debugPrint('[sync] batch non-200, body=${userResp.body}');
      return;
    }

    Map<String, dynamic> userMap;
    try {
      userMap = jsonDecode(userResp.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[sync] batch json parse error: $e, body=${userResp.body}');
      return;
    }

    final uCode = userMap['code'] as int? ?? -1;
    if (uCode != 0) {
      debugPrint('[sync] batch code=$uCode, msg=${userMap['message']}');
      return;
    }

    final List<dynamic> uData = userMap['data'] ?? [];
    debugPrint('[sync] batch returned ${uData.length} users');

// 3) 本地统一 upsert（服务器数据覆盖本地）
    final batch = db.batch();
    for (final u in uData) {
      final m = u as Map<String, dynamic>;
      final uid = m['id'] as String? ?? '';
      if (uid.isEmpty) continue;

      batch.insert(
        'users',
        {
          'id': uid,
          'name': m['name'] as String? ?? '',
          'avatar': m['avatar'] as String?,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      debugPrint('[sync] upsert user from server: $uid');
    }

    await batch.commit(noResult: true);
    debugPrint('[sync] users sync commit done');
  }



  /// 登出：清空内存与本地缓存
  Future<void> logout() async {
    debugPrint('logout start');
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUserIdKey);
    await prefs.remove(_kUserNameKey);
    await prefs.remove(_kAvatarKey);
    notifyListeners();
    debugPrint('logout end');
  }

  /// 更新头像路径
  Future<void> updateAvatar(File? file) async {
    final user = _currentUser;
    final token = user?.token;
    if (user == null || token == null) return;

    if (file == null) {
      // 调用服务端删除或置空接口，若没有接口可直接置空本地并返回
      await _setAvatarLocal(null);
      return;
    }

    // 上传逻辑...
    final uri = Uri.parse('${_apiBaseUrl}/api/users/avatar');
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(await http.MultipartFile.fromPath('file', file.path));

    final streamed = await req.send().timeout(const Duration(seconds: 20));
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode != 200) throw Exception('上传失败：${resp.statusCode}');
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    if ((map['code'] as int? ?? -1) != 0) throw Exception(map['message'] ?? '上传失败');
    final url = (map['data'] as Map<String, dynamic>?)?['url'] as String?;
    if (url == null || url.isEmpty) throw Exception('上传失败：无返回 url');

    await _setAvatarLocal(url);
  }

  Future<void> _setAvatarLocal(String? url) async {
    final user = _currentUser;
    if (user == null) return;
    _currentUser = user.copyWith(avatar: url);
    final db = await DatabaseService.instance.database;
    await db.update('users', {'avatar': url}, where: 'id = ?', whereArgs: [user.id]);
    notifyListeners();
  }

  /// 更新用户名：先更新服务器，成功后更新本地 db 与缓存
  Future<void> updateName(String name) async {
    final user = _currentUser;
    final token = user?.token;
    if (user == null || token == null) {
      debugPrint('[updateName] no user/token');
      return;
    }

    final uri = Uri.parse('${_apiBaseUrl}/api/users/name');
    debugPrint('[updateName] PUT $uri token=${token.substring(0, 8)}... new="$name"');

    http.Response resp;
    try {
      resp = await http
          .put(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'name': name}),
      )
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('[updateName] request error: $e');
      rethrow;
    }

    debugPrint('[updateName] http=${resp.statusCode} body=${resp.body}');
    if (resp.statusCode != 200) throw Exception('修改失败：${resp.statusCode}');
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final code = map['code'] as int? ?? -1;
    if (code != 0) throw Exception(map['message']?.toString() ?? '修改失败');

    // 服务端成功后本地落地
    _currentUser = User(
      id: user.id,
      name: name,
      avatar: user.avatar,
      token: user.token,
    );

    final db = await DatabaseService.instance.database;
    final rows = await db.update(
      'users',
      {'name': name},
      where: 'id = ?',
      whereArgs: [user.id],
    );
    debugPrint('[updateName] local db updated rows=$rows');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUserNameKey, name);
    debugPrint('[updateName] prefs saved');

    notifyListeners();
    debugPrint('[updateName] success -> $name');
  }

  String initials() {
    final name = _currentUser?.name ?? '';
    if (name.isEmpty) return '';
    return name.substring(0, 1).toUpperCase();
  }

  bool get hasAvatarFile { // 改为网络图后弃用
    final path = _currentUser?.avatar;
    return path != null && path.isNotEmpty && File(path).existsSync();
  }

  bool get hasAvatarUrl =>
      (_currentUser?.avatar?.startsWith('http') ?? false);


}