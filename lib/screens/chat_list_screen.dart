import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';//时间格式化
import 'package:third_app/screens/select_contact_screen.dart';
import '../models/user.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../models/chat.dart';

import '../services/database_service.dart';
import '../widgets/bottom_nav.dart';
import 'chat_screen.dart';
import 'contacts_screen.dart';
import 'me_screen.dart';

/// 聊天列表页面 - 显示所有聊天会话
class ChatListScreen extends StatefulWidget {//需要在页面创建时触发数据加载以及在页面生命周期内可能会有交互改变
  const ChatListScreen({Key? key}) : super(key: key);

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {


  List<User> contacts = [];

  @override
  void initState() {
    super.initState();
    // 初始化加载聊天列表
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatService>().loadChats();//通过 Provider 读取 ChatService，并触发加载会话列表
    });
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    final db = await DatabaseService.instance.database;
    final auth = context.read<AuthService>();
    final myId = auth.currentUser!.id;
    final result = await db.rawQuery(
      '''
    SELECT * FROM users WHERE id IN (
      SELECT contactId1 FROM contacts WHERE contactId2 = ?
      UNION
      SELECT contactId2 FROM contacts WHERE contactId1 = ?
    )
    ''',
      [myId, myId],
    );

    setState(() {
      contacts = result
          .map((map) => User(
        id: map['id'] as String,
        name: map['name'] as String? ?? "",
        avatar: map['avatar'] as String?,
      ))
          .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold( //Scaffold 提供页面基础结构：AppBar、body、FloatingActionButton
      appBar: AppBar(
        title: const Text('聊天'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SelectContactScreen()),
              );
            },
          ),
        ],
      ),
      body: Consumer<ChatService>(// Consumer 会监听 ChatService 的变化，当数据变化时会重建 builder 内部的 UI
        builder: (context, chatService, child) {

          if (chatService.chats.isEmpty) {// 没有聊天数据时显示占位文案
            return const Center(
              child: Text('暂无聊天记录\n点击右上角 + 创建新对话'),
            );
          }

          // 使用ListView.builder优化长列表性能
          return ListView.builder(
            itemCount: chatService.chats.length,
            itemExtent: 80.0,// 关键优化：itemExtent 指定每个列表项的固定高度，有助于滚动性能
            itemBuilder: (context, index) {
              final chat = chatService.chats[index];
              return Dismissible(
                key: ValueKey(chat.id),
                direction: DismissDirection.endToStart, // 仅允许向左滑
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  color: Colors.red,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: const [
                      Icon(Icons.delete, color: Colors.white),
                      SizedBox(width: 6),
                      Text('删除', style: TextStyle(color: Colors.white, fontSize: 14)),
                    ],
                  ),
                ),
                confirmDismiss: (d) async {
                  return await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('确认删除'),
                      content: Text('删除会话：${chat.name}？'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
                      ],
                    ),
                  ) ?? false;
                },
                onDismissed: (_) async {
                  await context.read<ChatService>().deleteChat(chat.id);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已删除 ${chat.name}')),
                  );
                },
                child: ChatListItem(
                  chat: chat,
                  onTap: () => _openChat(chat),
                ),
              );
            },
          );
        },
      ),
      //bottomNavigationBar: buildAppBottomNav(context, 0),
    );
  }


  /// 打开聊天详情
  void _openChat(Chat chat) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(chat: chat),
      ),
    );
  }
}


/// 单个聊天列表项组件（无状态组件，负责展示单条会话）
/// 分拆成独立组件有助于代码清晰、复用与局部重建优化
class ChatListItem extends StatelessWidget {
  final Chat chat;
  final VoidCallback onTap;

  const ChatListItem({
    super.key,
    required this.chat,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final currentUserId = context.read<AuthService>().currentUser!.id;

    final peerId = _getPeerId(chat, currentUserId);

    final Future<User?> peerFuture =
    context.read<AuthService>().getUserById(peerId);

    return FutureBuilder<User?>(
    future: peerFuture,
    builder: (context, snapshot) {
        final peer = snapshot.data;

        final name = peer?.name;
        final displayName =
        (name != null && name.isNotEmpty) ? name : '未知用户';
        final avatarPath = peer?.avatar;

        return InkWell(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: Colors.grey[300],
                  backgroundImage: (avatarPath != null && avatarPath.isNotEmpty)
                      ? NetworkImage(avatarPath)
                      : null,
                  child: (avatarPath == null || avatarPath.isEmpty)
                      ? Text(
                    displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        chat.lastMessage ?? '暂无消息',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _getPeerId(Chat chat, String currentUserId) {
    // 兼容你现在 participantIds 可能是 ["u1,u2"] 或 ["u1","u2"]
    final cleanedIds = <String>{
      for (final s in chat.participantIds)
        ...s
            .split(',')
            .map((x) => x.replaceAll('"', '').trim())
            .where((x) => x.isNotEmpty)
    }.toList();

    return cleanedIds.firstWhere(
          (id) => id != currentUserId,
      orElse: () => currentUserId,
    );
  }
}