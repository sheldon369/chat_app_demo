import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import '../models/user.dart';
import '../models/message.dart';
import '../models/chat.dart';
import 'auth_service.dart';
import 'database_service.dart';
import 'file_service.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

/// 聊天服务 - 处理聊天业务逻辑
class ChatService extends ChangeNotifier
{
  final AuthService authService;
  final DatabaseService _dbService = DatabaseService.instance; //数据库，读写聊天数据
  final FileService _fileService = FileService.instance;//文件存储，保存图片和表情
  final ImagePicker _imagePicker = ImagePicker();//图片选择器，用户从相册选择图片发送

  List<Chat> _chats = [];//内存中的聊天会话列表，用于UI显示
  Map<String, List<Message>> _messagesCache = {};//每个chat对应的消息缓存
  List<Chat> get chats => _chats;//对外只读的会话列表

  ChatService({required this.authService});

  http.Client? _sseClient;
  StreamSubscription<String>? _sseSub;
  String _sseBuffer = '';

  List<Message> messagesOf(String chatId) {
    return _messagesCache[chatId] ?? const [];
  }

  /// sse新增
  Future<void> startSseListener({String? chatId}) async {
    debugPrint('[SSE] startSseListener, chatId=$chatId');
    // 防止重复连接
    await stopSseListener();

    final token = authService.token;
    if (token == null || token.isEmpty) {
      print('startSseListener: token is empty');
      return;
    }

    final uri = Uri.parse(
      chatId != null
          ? '${authService.apiBaseUrl}/api/stream?chatId=$chatId'
          : '${authService.apiBaseUrl}/api/stream',
    );

    debugPrint('[SSE] connecting to $uri');

    _sseClient = http.Client();
    final req = http.Request('GET', uri)
      ..headers['Authorization'] = 'Bearer $token';

    final resp = await _sseClient!.send(req);

    debugPrint(
      '[SSE] connected, status=${resp.statusCode}, '
          'headers=${resp.headers}',
    );

    _sseSub = resp.stream.transform(utf8.decoder).listen(
      _onSseChunk,
      onError: (e) {
        print('SSE error: $e');
      },
      onDone: () {
        print('SSE closed');
      },
      cancelOnError: true,
    );
  }

  /// chunk解析函数
  void _onSseChunk(String chunk) {
    debugPrint('[SSE] chunk received: ${chunk.length} bytes');
    _sseBuffer += chunk;

    while (_sseBuffer.contains('\n\n')) {
      final idx = _sseBuffer.indexOf('\n\n');
      final event = _sseBuffer.substring(0, idx);
      _sseBuffer = _sseBuffer.substring(idx + 2);

      for (final line in const LineSplitter().convert(event)) {
        if (line.startsWith('data: ')) {
          final jsonStr = line.substring(6);

          debugPrint('[SSE] data line: $jsonStr');

          final msg = jsonDecode(jsonStr) as Map<String, dynamic>;
          _handleIncomingMessage(msg);
        }
      }
    }
  }

  /// 处理服务端推送的逻辑
  Future<void> _handleIncomingMessage(Map<String, dynamic> data) async {

    //加入去重逻辑
    final msgId = data['id'] as String;
    final chatId = data['chatId'] as String;

    final list = _messagesCache[chatId];
    if (list != null && list.any((m) => m.id == msgId)) {
      debugPrint('[SSE] duplicate message ignored: $msgId');
      return;
    }



    debugPrint('[SSE] handleIncomingMessage: ${data['id']}');
    final msg = Message(

      id: data['id'],
      chatId: data['chatId'],
      senderId: data['senderId'],
      senderName: data['senderName'],
      type: MessageType.values[data['type']],
      content: data['content'],
      timestamp: DateTime.fromMillisecondsSinceEpoch(data['timestamp']),
    );

    // 1) 写本地 DB（去重靠主键）
    await _dbService.insertMessage(msg);

    // 2) 更新内存缓存
    if (list != null) {
      list.insert(0, msg);
    }

    // 3) 更新会话 lastMessage
    await _updateChatLastMessage(
      msg.chatId,
      msg.type == MessageType.text
          ? msg.content
          : msg.type == MessageType.image
          ? '[picture]'
          : '[emoji]',
      msg.timestamp,
    );

    debugPrint('[SSE] notifyListeners()');
    notifyListeners();
  }

  ///关闭逻辑
  Future<void> stopSseListener() async {
    await _sseSub?.cancel();
    _sseSub = null;

    _sseClient?.close();
    _sseClient = null;

    _sseBuffer = '';
  }

  /// 首次进入某个聊天时，从本地 DB 加载消息（只执行一次）
  Future<void> loadMessagesIfNeeded(String chatId) async {
    // 已经加载过就不再重复加载
    if (_messagesCache.containsKey(chatId)) {
      return;
    }

    // 从本地数据库读取最新一页消息
    final messages = await _dbService.getMessagesByChat(
      chatId,
      limit: 50,
      offset: 0,
    );

    _messagesCache[chatId] = messages;

    notifyListeners();
  }

  @override
  void dispose() {
    stopSseListener(); // 关闭 SSE
    super.dispose();
  }


  /// 初始化聊天服务
  Future<void> initialize() async {
    debugPrint('[ChatService] initialize() start');

    await loadChats();

    debugPrint('[ChatService] loadChats done, start SSE');

    // await startSseListener();
    //
    // debugPrint('[ChatService] SSE listener started');
  }

  //用户登陆后调用，建立sse
  Future<void> onLogin() async {
    debugPrint('[ChatService] onLogin');

    // 清理旧状态（防止热重载 / 重登录）
    await stopSseListener();
    _messagesCache.clear();
    _chats.clear();

    // 重新加载数据
    await loadChats();

    // 启动 SSE（此时 token 一定存在）
    await startSseListener();

    debugPrint('[ChatService] SSE started after login');
  }

  Future<void> onLogout() async {
    debugPrint('[ChatService] onLogout');

    await stopSseListener();

    _messagesCache.clear();
    _chats.clear();

    notifyListeners();
  }

  /// 加载所有聊天会话
  Future<void> loadChats() async
  {
    final user = authService.currentUser;

    if (user == null) {
      print('loadChats() called but currentUser is null');
      return;
    }


    _chats = await _dbService.getAllChats();
    notifyListeners();
  }

  /// 创建新的聊天会话
  /// name: 会话显示名
  /// participantIds: 参与者 ID 列表（字符串形式）
  Future<Chat> createChat(String chatName, List<String> participantIds) async {
    if (participantIds.length != 2) {
      throw Exception('目前仅支持一对一聊天');
    }

    // 1) 排序，保证唯一性
    final sortedIds = List<String>.from(participantIds)..sort();
    final participantStr = sortedIds.join(',');

    // 2) 取 token
    final token = authService.currentUser?.token;
    if (token == null || token.isEmpty) {
      throw Exception('未登录或 token 为空');
    }

    // 3) 先请求服务端 /api/chats/add
    final uri = Uri.parse('${authService.apiBaseUrl}/api/chats/add');
    final resp = await http.post(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'name': chatName,
        'participantIds': sortedIds, // 服务器示例是数组
        'lastMessage': '',           // 可选字段
      }),
    );

    if (resp.statusCode != 200) {
      throw Exception('创建聊天失败：HTTP ${resp.statusCode}');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    if ((map['code'] as int? ?? -1) != 0) {
      throw Exception(map['message'] ?? '创建聊天失败');
    }
    final data = map['data'] as Map<String, dynamic>?;
    final chatId = data?['id'] as String?;
    if (chatId == null || chatId.isEmpty) {
      throw Exception('创建聊天失败：未返回聊天 ID');
    }

    // 4) 本地 upsert
    final db = await _dbService.database;
    final now = DateTime.now();
    final chat = Chat(
      id: chatId,
      name: chatName,
      participantIds: sortedIds,
      lastMessage: null,
      lastMessageTime: now,
      unreadCount: 0,
    );

    await db.insert(
      'chats',
      chat.toMap()..['participantIds'] = participantStr,
      conflictAlgorithm: ConflictAlgorithm.replace, // 避免重复插入导致报错
    );

    // 5) 刷新内存
    await loadChats();
    return chat;
  }


  /// 删除聊天会话及其相关消息
  Future<void> deleteChat(String chatId) async {
    // 1) 准备 token
    final token = authService.currentUser?.token;
    if (token == null || token.isEmpty) {
      throw Exception('未登录或 token 为空');
    }

    // 2) 调用服务端删除接口（按你实际路由调整，示例用 DELETE /api/chats/{id}）
    final uri = Uri.parse('${authService.apiBaseUrl}/api/chats/$chatId');
    final resp = await http.delete(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
    );

    if (resp.statusCode != 200) {
      throw Exception('删除聊天失败：HTTP ${resp.statusCode}');
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    if ((map['code'] as int? ?? -1) != 0) {
      throw Exception(map['message'] ?? '删除聊天失败');
    }

    // 3) 本地删除并刷新内存
    await _dbService.deleteChat(chatId);
    await loadChats();
  }


  /// 分页加载聊天消息
  Future<List<Message>> loadMessages(
      String chatId, {
        int limit = 50,//默认每页50条
        int offset = 0,//offset更新内存缓存
      }) async
  {
    final messages = await _dbService.getMessagesByChat(
      chatId,
      limit: limit,
      offset: offset,
    );


    if (offset == 0) {// 若当前消息为新消息，则缓存
      _messagesCache[chatId] = messages;
    }

    return messages;
  }


  /// 生成唯一的客户端消息 ID，以验证超时重发等场景
  String _genClientMsgId(String senderId) {
    final r = Random();
    final ts = DateTime.now().microsecondsSinceEpoch; // 时间戳提高唯一性
    final rand = r.nextInt(1 << 32);                 // 随机 32 位
    return '$senderId-$ts-$rand';
  }


  /// 发送文本消息
  Future<void> sendTextMessage(
      String chatId,
      String senderId,
      String senderName,
      String text,
      ) async
  {
    final clientMsgId = _genClientMsgId(senderId);; // 幂等用
    final now = DateTime.now();

    // 1) 先发给服务器
    final resp = await http.post(
      Uri.parse('${authService.apiBaseUrl}/api/messages/send'), // 按你的后端改路径
      headers: {
        'Authorization': 'Bearer ${authService.token}', // 若无需鉴权可去掉
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'chatId': chatId,
        'clientMsgId': clientMsgId,
        'type': MessageType.text.index, // 如果后端用数字；若用字符串则改成 "text"
        'content': text,
      }),
    );

    if (resp.statusCode != 200) {
      throw Exception('发送失败: ${resp.statusCode}');
    }

    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if ((body['code'] as int? ?? -1) != 0) {
      throw Exception(body['message'] ?? '发送失败');
    }
    // final data = body['data'] as Map<String, dynamic>;
    //
    // // 2) 用服务器回的正式 id/timestamp 生成消息
    // final msg = Message(
    //   id: data['id'] ?? clientMsgId, // 兜底用 clientMsgId
    //   chatId: chatId,
    //   senderId: data['senderId'] ?? senderId,
    //   senderName: data['senderName'] ?? senderName,
    //   type: MessageType.text,
    //   content: data['content'] ?? text,
    //   timestamp: data['timestamp'] != null
    //       ? DateTime.fromMillisecondsSinceEpoch(data['timestamp'])
    //       : now,
    // );

    // // 3) 落本地库 & 更新会话
    // await _dbService.insertMessage(msg);
    // await _updateChatLastMessage(chatId, msg.content, msg.timestamp);
    //
    // // 4) 更新缓存
    // _messagesCache[chatId]?.insert(0, msg);
    // notifyListeners();
  }

  /// 上传图片文件，返回服务器存储信息
  Future<Map<String, dynamic>> _uploadImageFile({
    required String filePath,
    required String token,
  }) async
  {
    final uri = Uri.parse('${authService.apiBaseUrl}/api/files/upload'); // 按你后端路由修改
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(await http.MultipartFile.fromPath('file', filePath,
          filename: p.basename(filePath)));

    final resp = await req.send();
    final body = await http.Response.fromStream(resp);

    if (body.statusCode != 200) {
      throw Exception('上传失败: ${body.statusCode}');
    }
    final json = jsonDecode(body.body) as Map<String, dynamic>;
    if ((json['code'] as int? ?? -1) != 0) {
      throw Exception(json['message'] ?? '上传失败');
    }
    // 约定返回 { path, fileName, fileSize, width, height, createdAt }
    return json['data'] as Map<String, dynamic>;
  }


  /// 发送图片消息
  Future<void> sendImageMessage(
      String chatId,
      String senderId,
      String senderName,
      ) async
  {
    // 1) 选图
    final XFile? image = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (image == null) return;

    final token = authService.token; // 替换为你的取 token 方式

    if (token == null || token.isEmpty) {
      throw Exception('缺少登录 token，无法上传图片');
    }

    // 2) 上传文件
    final uploadInfo = await _uploadImageFile(
      filePath: image.path,
      token: token,
    );

    // 3) 调用发送消息接口（content 放服务器路径）
    final clientMsgId = _genClientMsgId(senderId);
    final resp = await http.post(
      Uri.parse('${authService.apiBaseUrl}/api/messages/send'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'chatId': chatId,
        'clientMsgId': clientMsgId,
        'type': MessageType.image.index, // 或后端定义的图片类型值
        'content': uploadInfo['path'],   // 服务器返回的存储路径/URL
      }),
    );

    if (resp.statusCode != 200) {
      throw Exception('发送失败: ${resp.statusCode}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if ((body['code'] as int? ?? -1) != 0) {
      throw Exception(body['message'] ?? '发送失败');
    }
    // final data = body['data'] as Map<String, dynamic>;

    // // 4) 写本地库（用服务器返回的 id/timestamp）
    // final msg = Message(
    //   id: data['id'],
    //   chatId: chatId,
    //   senderId: data['senderId'] ?? senderId,
    //   senderName: data['senderName'] ?? senderName,
    //   type: MessageType.image,
    //   content: data['content'], // 服务器路径
    //   timestamp: DateTime.fromMillisecondsSinceEpoch(data['timestamp']),
    // );
    // await _dbService.insertMessage(msg);

    // 5) 写 image_files 表（用服务器返回的文件信息）
    // await _dbService.insertImageFile({
    //   'id': uploadInfo['id'] ?? _genClientMsgId(senderId),
    //   'messageId': msg.id,
    //   'filePath': uploadInfo['path'],
    //   'fileName': uploadInfo['fileName'],
    //   'fileSize': uploadInfo['fileSize'],
    //   'width': uploadInfo['width'],
    //   'height': uploadInfo['height'],
    //   'createdAt': uploadInfo['createdAt'],
    // };


    // await _updateChatLastMessage(chatId, '[picture]',msg.timestamp);
    // _messagesCache[chatId]?.insert(0, msg);
    // notifyListeners();
  }

  /// 发送表情消息 这里表情不允许自定义，因此当文本发送就可以
  Future<void> sendEmojiMessage(
      String chatId,
      String senderId,
      String senderName,
      String emojiPath, // 本地资源路径，如 assets/emojis/xxx.png
      ) async
  {
    final clientMsgId = _genClientMsgId(senderId);
    ; // 幂等用
    final now = DateTime.now();

    // 1) 先发给服务器
    final resp = await http.post(
      Uri.parse('${authService.apiBaseUrl}/api/messages/send'), // 按你的后端改路径
      headers: {
        'Authorization': 'Bearer ${authService.token}', // 若无需鉴权可去掉
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'chatId': chatId,
        'clientMsgId': clientMsgId,
        'type': MessageType.emoji.index, // 如果后端用数字；若用字符串则改成 "text"
        'content': emojiPath,
      }),
    );

    if (resp.statusCode != 200) {
      throw Exception('发送失败: ${resp.statusCode}');
    }

    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if ((body['code'] as int? ?? -1) != 0) {
      throw Exception(body['message'] ?? '发送失败');
    }
    // final data = body['data'] as Map<String, dynamic>;

    // // 2) 用服务器回的正式 id/timestamp 生成消息
    // final msg = Message(
    //   id: data['id'] ?? clientMsgId,
    //   // 兜底用 clientMsgId
    //   chatId: chatId,
    //   senderId: data['senderId'] ?? senderId,
    //   senderName: data['senderName'] ?? senderName,
    //   type: MessageType.emoji,
    //   content: data['content'] ?? emojiPath,
    //   timestamp: data['timestamp'] != null
    //       ? DateTime.fromMillisecondsSinceEpoch(data['timestamp'])
    //       : now,
    // );

    // // 3) 落本地库 & 更新会话
    // await _dbService.insertMessage(msg);
    // await _updateChatLastMessage(chatId, '[emoji]', msg.timestamp);
    //
    // // 4) 更新缓存
    // _messagesCache[chatId]?.insert(0, msg);
    // notifyListeners();
  }



  /// 更新聊天最后一条消息
  /// 用于在会话列表中显示最后一条消息的内容和时间
  /// 更新聊天最后一条消息
  Future<void> _updateChatLastMessage(
      String chatId,
      String lastMessage,
      DateTime ts,
      ) async {
    await _dbService.updateChatLastMessage(
      chatId,
      lastMessage,
      ts, // 不再用 DateTime.now()
    );
    await loadChats();
  }

  /// 标记消息为已读
  Future<void> markAsRead(String messageId) async {
    await _dbService.markMessageAsRead(messageId);
  }
}

