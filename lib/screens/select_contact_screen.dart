import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/User.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import 'dart:io';

import '../services/database_service.dart';
import '../widgets/bottom_nav.dart';
import 'chat_screen.dart';
import 'contacts_screen.dart';
import 'me_screen.dart';



class SelectContactScreen extends StatefulWidget {
  const SelectContactScreen({super.key});

  @override
  State<SelectContactScreen> createState() => _SelectContactScreenState();
}

class _SelectContactScreenState extends State<SelectContactScreen> {
  List<User> _contacts = [];

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    final auth = context.read<AuthService>();
    final db = await DatabaseService.instance.database;

    final userId = auth.currentUser!.id;

    // 查询所有好友（contacts 表）
    final result = await db.rawQuery(
      '''
      SELECT * FROM users WHERE id IN (
        SELECT contactId1 FROM contacts WHERE contactId2 = ?
        UNION
        SELECT contactId2 FROM contacts WHERE contactId1 = ?
      )
      ''',
      [userId, userId],
    );

    setState(() {
      _contacts = result
          .map((map) => User(
                id: map['id'] as String,
                name: map['name'] as String? ?? "",
                avatar: map['avatar'] as String?,
              ))
          .toList();
    });
  }

  Future<void> _startChat(User contact) async {
    final auth = context.read<AuthService>();
    final chatService = context.read<ChatService>();

    final myId = auth.currentUser!.id;
    final otherId = contact.id;

    // 创建聊天
    await chatService.createChat(
      "${auth.currentUser!.name}与${contact.name}的聊天",
      [myId, otherId],
    );

    Navigator.pop(context); // 返回聊天列表页面
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("选择联系人")),
      body: _contacts.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _contacts.length,
              itemBuilder: (context, index) {
                final user = _contacts[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundImage: user.avatar != null
                        ? NetworkImage(user.avatar!)
                        : null,
                    child: user.avatar == null ? const Icon(Icons.person) : null,
                  ),
                  title: Text(user.name ?? '无名用户'),
                  onTap: () => _startChat(user),
                );
              },
            ),
    );
  }
}
