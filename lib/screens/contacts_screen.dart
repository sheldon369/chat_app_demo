import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/user.dart';
import '../services/auth_service.dart';
import '/services/database_service.dart';

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({Key? key}) : super(key: key);

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {

  List<User> _contacts = []; // 页面状态，保存好友列表

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  /// 从数据库加载好友
  Future<void> _loadContacts() async {
    // 获取当前登录用户 ID
    final auth = context.read<AuthService>();
    final currentUserId = auth.currentUser?.id;

    if (currentUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("当前用户未登录")),
      );
      return;
    }

    // 调用 DatabaseService 获取好友列表
    final contacts = await DatabaseService.instance.getAllContacts(currentUserId);

    // 按名字首字母排序（可选）
    contacts.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));

    // 更新页面状态
    setState(() {
      _contacts = contacts;
    });
  }

  /// 添加好友
  Future<void> _addFriend() async {
    final controller = TextEditingController();
    final userId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加好友'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: '请输入用户 ID',
          ),
        ),
        actions: [
          TextButton(
            child: const Text('取消'),
            onPressed: () => Navigator.pop(context),
          ),
          TextButton(
            child: const Text('确定'),
            onPressed: () {
              Navigator.pop(context, controller.text.trim());
            },
          ),
        ],
      ),
    );

    if (userId == null || userId.isEmpty) return;

    // 获取当前登录用户
    final auth = context.read<AuthService>();
    final currentUserId = auth.currentUser?.id;

    if (currentUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("当前用户未登录")),
      );
      return;
    }

    // 调用数据库的 addContact
    final msg = await DatabaseService.instance.addContact(
      userId,
    );

    // 显示结果提示
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );

    // 成功后刷新联系人列表
    if (msg == "好友添加成功") {
      _loadContacts(); // 假设你有这个函数
    }
  }

  @override
  Widget build(BuildContext context) {


    return Scaffold(
      appBar: AppBar(
        title: const Text('通讯录'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _addFriend,
          ),
        ],
      ),
      body: _contacts.isEmpty
          ? const Center(child: Text('暂无联系人'))
          : ListView.builder(
        itemCount: _contacts.length,
        itemBuilder: (context, index) {
          final friend = _contacts[index]; // friend 是 User 类型
          final hasAvatar = friend.avatar != null && friend.avatar!.isNotEmpty;
          return ListTile(
            leading: CircleAvatar(
              radius: 24,
              backgroundImage: hasAvatar
                  ? NetworkImage(friend.avatar!) // 确认这里是可访问的 URL
                  : null,
              child: hasAvatar
                  ? null
                  : const Icon(Icons.person, color: Colors.grey),
            ),
            title: Text(friend.name ?? friend.id),
            subtitle: Text("ID: ${friend.id}"),
            onTap: () {
              // TODO: 跳转聊天页面
            },
          );
        },
      ),
    );
  }
}

