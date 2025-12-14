import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/message.dart';
import '../models/chat.dart';
import '../models/user.dart';
import 'auth_service.dart';
import 'package:http/http.dart' as http; // NEW: HTTP 客户端


/// 数据库服务 - 负责所有数据库操作
/// 负责：
/// 1. 初始化并维护本地 SQLite 数据库（单例）
/// 2. 提供聊天相关（会话、消息、图片文件元数据）的 CRUD 操作
/// 3. 对批量写入、分页查询等进行简单性能优化
///
/// 使用方式：
///   final dbService = DatabaseService.instance;
///   await dbService.insertMessage(message);

class DatabaseService {
  static final DatabaseService instance = DatabaseService._init(); // 单例实例
  static Database? _database; //真正持有的数据库对象
  DatabaseService._init();

  // 这里直接取 AuthService 单例
  final AuthService _auth = AuthService.instance;
  AuthService get auth => _auth; // 可选暴露，便于调用处使用


  /// 获取数据库实例（单例模式）
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('chat_app.db');
    return _database!;
  }
  ///调用方式：final db = await DatabaseService.instance.database;

  /// 根据用户ID获取用户信息
  Future<User?> getUserById(String userId) async {
    final db = await database;

    final rows = await db.query(
      'users',
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );

    if (rows.isEmpty) return null;

    return User.fromMap(rows.first);
  }



  /// 初始化数据库
  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath(); // 获取系统默认数据库存储路径
    final path = join(dbPath, filePath);
    debugPrint('[db] open -> $path'); // 打印即将打开的绝对路径
    return await openDatabase(
      path,
      version: 1,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON;');
        await db.rawQuery('PRAGMA journal_mode=DELETE;');
      },
      onCreate: _createDB,
    );

  }


  /// 创建数据库表
  Future<void> _createDB(Database db, int version) async {
    debugPrint('[db] onCreate at ${db.path}, version=$version');
    /// 创建用户表
    await db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        avatar TEXT
      )
    ''');

    /// 创建聊天会话表
    await db.execute('''
      CREATE TABLE IF NOT EXISTS chats (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        participantIds TEXT NOT NULL,
        lastMessage TEXT,
        lastMessageTime INTEGER,
        unreadCount INTEGER DEFAULT 0
      )
    ''');

    /// 创建消息表 - 添加索引以优化查询性能
    await db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id TEXT PRIMARY KEY,
        chatId TEXT NOT NULL,
        senderId TEXT NOT NULL,
        senderName TEXT NOT NULL,
        type INTEGER NOT NULL,
        content TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        isRead INTEGER DEFAULT 0

      )
    ''');

    // 为chatId创建索引，优化聊天记录查询
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_chatId ON messages(chatId, timestamp DESC)
    ''');

    // // 创建图片信息表 - 存储图片元数据
    // await db.execute('''
    //   CREATE TABLE IF NOT EXISTS image_files (
    //     id TEXT PRIMARY KEY,
    //     messageId TEXT NOT NULL,
    //     filePath TEXT NOT NULL,
    //     fileName TEXT NOT NULL,
    //     fileSize INTEGER NOT NULL,
    //     width INTEGER,
    //     height INTEGER,
    //     createdAt INTEGER NOT NULL,
    //     FOREIGN KEY (messageId) REFERENCES messages (id) ON DELETE CASCADE
    //   )
    // ''');

    // 创建联系人表
    await db.execute('''
      CREATE TABLE IF NOT EXISTS contacts (
        id INTEGER PRIMARY KEY,
        contactId1 TEXT NOT NULL,
        contactId2 TEXT NOT NULL,
        status TEXT NOT NULL,
        createdAt INTEGER NOT NULL
      )
    ''');
    debugPrint('[db] users table created');
  }


  // ==================== 用户操作 ====================

  /// 插入测试用户数据(在设计注册逻辑之前)
  Future<void> insertTestUsers(Database db) async {
    List<Map<String, String>> testUsers = [
      {
        'id': 'u001',
        'name': 'Alice',
        'avatar': '',
        'passwordHash': '1', // 测试用，真实项目请哈希处理
      },
      {
        'id': 'u002',
        'name': 'Bob',
        'avatar': '',
        'passwordHash': '2',
      },
      {
        'id': 'u003',
        'name': 'Charlie',
        'avatar': '',
        'passwordHash': '3',
      },
      {
        'id': 'u004',
        'name': 'Diana',
        'avatar': '',
        'passwordHash': '4',
      }
    ];

    for (var user in testUsers) {
      await db.insert(
        'users',
        user,
        conflictAlgorithm: ConflictAlgorithm.replace, // 如果主键重复就覆盖
      );
    }
  }

  /// DatabaseService avatar
  Future<String?> getUserAvatar(String userId) async {
    if (userId.isEmpty) return null;
    final db = await database;
    final rows = await db.query(
      'users',
      columns: ['avatar'],
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final avatar = rows.first['avatar'] as String?;
    return (avatar != null && avatar.isNotEmpty) ? avatar : null;
  }



  // ==================== 聊天会话操作 ====================

  /// 插入或更新聊天会话
  Future<void> insertChat(Chat chat) async {
    final db = await database;
    await db.insert(
      'chats',
      chat.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace, //避免主键冲突时报错（替换旧记录）
    );
  }


  Future<int> deleteChat(String chatId) async {
    final db = await database;
    final count = await db.delete(
      'chats',
      where: 'id = ?',
      whereArgs: [chatId],
    );
    return count;
  }

  /// 获取所有聊天会话（按最后消息时间排序）
  Future<List<Chat>> getAllChats() async {
    final db = await database;
    final maps = await db.rawQuery(
      '''
    SELECT * FROM chats
    ORDER BY lastMessageTime DESC
    ''',
    );
    return maps.map((map) => Chat.fromMap(map)).toList();
  }


  /// 更新聊天会话的最后消息
  Future<void> updateChatLastMessage(String chatId,
      String lastMessage,
      DateTime lastMessageTime,) async
  {
    final db = await database;
    await db.update(
      'chats',
      {
        'lastMessage': lastMessage,
        'lastMessageTime': lastMessageTime.millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  // ==================== 消息操作 ====================



  /// 插入消息
  Future<void> insertMessage(Message message) async
  {
    final db = await database;
    await db.insert(
      'messages',
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 批量插入消息（带 debug）
  Future<void> insertMessages(List<Map<String, dynamic>> maps) async {
    debugPrint('[insertMessages] incoming=${maps.length}');
    if (maps.isEmpty) return;

    final db = await database;
    final batch = db.batch();

    for (final m in maps) {
      // 打印关键字段方便排查
      debugPrint('[insertMessages] push id=${m['id']} chatId=${m['chatId']} ts=${m['createdAt'] ?? m['timestamp']}');
      batch.insert(
        'messages',
        m,
        conflictAlgorithm: ConflictAlgorithm.ignore, // 重复跳过
      );
    }

    final results = await batch.commit(noResult: false);
    // results 里是每个操作的返回值或 null（取决于驱动）
    debugPrint('[insertMessages] committed count=${results.length}');
    for (var i = 0; i < results.length; i++) {
      debugPrint('[insertMessages] result[$i]=${results[i]}');
    }
  }

  /// 分页获取聊天消息（优化性能，避免一次加载过多数据）
  Future<List<Message>> getMessagesByChat(String chatId, {
    int limit = 50,
    int offset = 0,
  }) async
  {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'messages',
      where: 'chatId = ?',
      whereArgs: [chatId],
      orderBy: 'timestamp DESC',
      limit: limit,
      offset: offset,
    );
    return maps.map((map) => Message.fromMap(map)).toList();
  }

  /// 标记消息为已读 -- 暂不使用
  Future<void> markMessageAsRead(String messageId) async
  {
    final db = await database;
    await db.update(
      'messages',
      {'isRead': 1},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  Future<int?> getLastMessageTime(String chatId) async {
    final db = await database; // 替换为你获取数据库实例的方式
    final rows = await db.query(
      'chats',
      columns: ['lastMessageTime'],
      where: 'id = ?',
      whereArgs: [chatId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final v = rows.first['lastMessageTime'];
    if (v == null) return null;
    if (v is int) return v;
    return int.tryParse(v.toString());
  }

  // ==================== 图片文件信息操作 ====================

  /// 保存图片文件信息
  Future<void> insertImageFile(Map<String, dynamic> imageInfo) async {
    final db = await database;
    await db.insert(
      'image_files',
      imageInfo,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 获取图片文件信息
  Future<Map<String, dynamic>?> getImageFile(String messageId) async
  {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'image_files',
      where: 'messageId = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    return maps.isNotEmpty ? maps.first : null;
  }

  // ==================== 好友操作 ====================

  /// 获取所有聊天会话（按最后消息时间排序）
  Future<List<User>> getAllContacts(String currentUserId) async {

    final db = await database;
    // 查询所有与当前用户相关的好友关系
    final records = await db.query(
      'contacts',
      where: '(contactId1 = ? OR contactId2 = ?) AND status = ?',
      whereArgs: [currentUserId, currentUserId, 'accepted'],
    );

    if (records.isEmpty) return [];

    List<User> contacts = [];

    for (final row in records) {
      // 找到好友的 userId（不是当前用户的那个）
      final friendId = row['contactId1'] == currentUserId
          ? row['contactId2'] as String
          : row['contactId1'] as String;

      // 查询好友在 users 表中的信息
      final userRows = await db.query(
        'users',
        where: 'id = ?',
        whereArgs: [friendId],
      );

      if (userRows.isEmpty) continue;

      final user = userRows.first;

      contacts.add(
        User(
          id: user['id'] as String,
          name: user['name'] as String?,
          avatar: user['avatar'] as String?,
        ),
      );
    }

    return contacts;
  }


  /// 添加好友关系
  /// 当前用户 currentUserId 想添加 targetUserId


  Future<String> addContact(String targetUserId) async {
    final db = await database;
    final token = _auth.token; // 你保存的登录 token
    if (token == null) return "未登录";

    // 1) 调用服务器添加联系人
    final uri = Uri.parse('${_auth.apiBaseUrl}/api/contacts/add');
    final resp = await http
        .post(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'targetId': targetUserId}),
    )
        .timeout(const Duration(seconds: 10));

    if (resp.statusCode != 200) {
      return "添加失败：${resp.statusCode}";
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final code = map['code'] as int? ?? -1;
    if (code != 0) {
      return map['message']?.toString() ?? "添加失败";
    }

    // 2) 写入本地 contacts 表（使用当前用户和目标用户原顺序）
    await db.insert(
      'contacts',
      {
        'contactId1': _auth.currentUser!.id,
        'contactId2': targetUserId,
        'status': 'accepted', // 与服务端保持一致
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore, // 防止重复插入
    );

    // 3) 拉取该好友资料，补全本地 users 表（失败则忽略）
    try {
      final userUri = Uri.parse('${_auth.apiBaseUrl}/api/users/batch?ids=$targetUserId');
      final userResp = await http
          .get(userUri, headers: {'Authorization': 'Bearer $token'})
          .timeout(const Duration(seconds: 8));

      if (userResp.statusCode == 200) {
        final userMap = jsonDecode(userResp.body) as Map<String, dynamic>;
        final uCode = userMap['code'] as int? ?? -1;
        if (uCode == 0 && userMap['data'] != null) {
          final u = userMap['data'] as Map<String, dynamic>;
          await db.insert(
            'users',
            {
              'id': u['id'] as String? ?? targetUserId,
              'name': u['name'] as String? ?? targetUserId,
              'avatar': u['avatar'] as String?,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          debugPrint('[contact] upsert user ${u['id']} to local users');
        } else {
          debugPrint('[contact] fetch user $targetUserId code=$uCode msg=${userMap['message']}');
        }
      } else {
        debugPrint('[contact] fetch user $targetUserId http=${userResp.statusCode} body=${userResp.body}');
      }
    } catch (e) {
      debugPrint('[contact] fetch user $targetUserId error: $e');
    }

    return "好友添加成功";
  }

  /// 覆盖写入联系人列表（用于同步服务器数据） 每次登录都完全删除原来的联系人数据，重新写入最新的联系人列表
  Future<void> overwriteContacts(List<Map<String, dynamic>> contacts) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('contacts');
      for (final c in contacts) {
        await txn.insert('contacts', {
          'contactId1': c['contactId1'],
          'contactId2': c['contactId2'],
          'status': c['status'],
          'createdAt': c['createdAt'],
        });
      }
    });
  }

  Future<void> overwriteChats(List<Map<String, dynamic>> chats) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('chats');
      for (final c in chats) {
        await txn.insert('chats', {
          'id': c['id'],
          'name': c['name'],
          'participantIds': c['participantIds'] ?? '[]',
          'lastMessage': c['lastMessage'],
          'lastMessageTime': c['lastMessageTime'],
          'unreadCount': c['unreadCount'] ?? 0,
        });
      }
    });
  }


  /// 关闭数据库连接
  Future<void> close() async {
    final db = await database;
    await db.close();
  }


  /// 服务器拉取数据库
  /// （1）从服务器同步联系人表到本地（全量覆盖）
  Future<void> syncContactsFromServer(AuthService authService) async {
    final user = authService.currentUser;
    if (user == null || user.token == null) {
      throw Exception('未登录或缺少 token');
    }

    // 1) 拉取服务器数据
    final uri = Uri.parse('${authService.apiBaseUrl}/api/contacts');
    final resp = await http
        .get(uri, headers: {'Authorization': 'Bearer ${user.token}'})
        .timeout(const Duration(seconds: 8));

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
        'createdAt': m['createdAt'] as int? ?? DateTime
            .now()
            .millisecondsSinceEpoch,
      };
    }).toList();

    // 2) 写入本地 DB（覆盖）
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('contacts'); // 清空旧数据
      for (final c in contacts) {
        await txn.insert('contacts', {
          'contactId1': c['contactId1'],
          'contactId2': c['contactId2'],
          'status': c['status'],
          'createdAt': c['createdAt'],
        });
      }
    });
  }


}