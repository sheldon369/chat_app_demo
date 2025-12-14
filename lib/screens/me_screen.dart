import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:sqflite/sqflite.dart';
import '../services/auth_service.dart';
import '../services/database_service.dart';
import '../services/test.dart';

class MeScreen extends StatefulWidget {

  const MeScreen({Key? key}) : super(key: key);
  @override
  State<MeScreen> createState() => _MeScreenState();
}

class _MeScreenState extends State<MeScreen> with SingleTickerProviderStateMixin {
  final ImagePicker _picker = ImagePicker();
  late TextEditingController _nameCtrl;
  late AnimationController _fadeCtrl;
  int ContactCount = 0;
  int ChatCount = 0;

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthService>();
    _nameCtrl = TextEditingController(text: auth.currentUser?.name ?? '');
    _fadeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))..forward();
    loadCount();
  }

  Future<void> loadCount() async {
    final auth = context.read<AuthService>();
    int countOfContacts = await getUserRelatedContactsCount(auth);
    int countOfChats = await getUserRelatedChatsCount(auth);
    setState(() {
      ContactCount = countOfContacts;
      ChatCount = countOfChats;
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatarSheet(AuthService auth) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(ctx).colorScheme.surface.withOpacity(.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 4),
            Container(
              height: 4,
              width: 46,
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            // ListTile(
            //   leading: const Icon(Icons.photo_camera_rounded),
            //   title: const Text('拍照'),
            //   onTap: () => Navigator.pop(ctx, ImageSource.camera),
            // ),
            // if (auth.hasAvatarUrl)
            //   ListTile(
            //     leading: const Icon(Icons.delete_forever, color: Colors.redAccent),
            //     title: const Text('移除头像'),
            //     onTap: () async { // 加 async
            //       Navigator.pop(ctx);
            //       try {
            //         await auth.updateAvatar(null); // 这里才可以 await
            //         if (context.mounted) {
            //           ScaffoldMessenger.of(context)
            //               .showSnackBar(const SnackBar(content: Text('头像已移除')));
            //         }
            //       } catch (e) {
            //         if (context.mounted) {
            //           ScaffoldMessenger.of(context)
            //               .showSnackBar(SnackBar(content: Text('移除失败：$e')));
            //         }
            //       }
            //     },
            //   ),
          ],
        ),
      ),
    );

    if (source == null) return;

    final picked = await _picker.pickImage(
      source: source,
      maxWidth: 640,
      maxHeight: 640,
      imageQuality: 85,
    );
    if (picked == null) return;

    try {
      await auth.updateAvatar(File(picked.path)); // 传 File
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('头像已更新')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('上传失败：$e')));
      }
    }
  }

  Future<void> _editName(AuthService auth) async {
    if (!auth.isAuthenticated) return;
    final ctrl = TextEditingController(text: _nameCtrl.text);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改名称'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '新名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              final v = ctrl.text.trim();
              if (v.isEmpty) return;
              Navigator.pop(ctx, v);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      auth.updateName(result.trim());
      _nameCtrl.text = result.trim();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('名称已更新')));
    }
  }

  Future<void> _confirmLogout(AuthService auth) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认注销'),
        content: const Text('确定要退出当前账号吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('注销'),
          ),
        ],
      ),
    );
    if (ok == true) _logout(auth);
  }

  Future<void> _logout(AuthService auth) async {
    if (!auth.isAuthenticated) return;
    await auth.logout();
  }

  Widget _glassCard({required Widget child, EdgeInsets padding = const EdgeInsets.all(16)}) {
    return AnimatedOpacity(
      opacity: 1,
      duration: const Duration(milliseconds: 600),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white.withOpacity(.18)),
              gradient: LinearGradient(
                colors: [
                  Colors.white.withOpacity(.55),
                  Colors.white.withOpacity(.30),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            padding: padding,
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthService>(
      builder: (_, auth, __) {
        final user = auth.currentUser;
        return Scaffold(
         // bottomNavigationBar: buildAppBottomNav(context, 2),
          body: CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: 230,
                centerTitle: true,
                title: const Text('个人中心'),
                flexibleSpace: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xFF4F76FF), Color(0xFF6EC4FF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: FlexibleSpaceBar(
                    background: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 32),
                        child: Center(
                          child: GestureDetector(
                            onTap: auth.isAuthenticated ? () => _pickAvatarSheet(auth) : null,
                            child: Hero(
                              tag: 'me.avatar',
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 500),
                                    curve: Curves.easeOut,
                                    width: 116,
                                    height: 116,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(.25),
                                          blurRadius: 18,
                                          offset: const Offset(0, 8),
                                        ),
                                      ],
                                      gradient: LinearGradient(
                                        colors: auth.hasAvatarFile
                                            ? [Colors.blueGrey.shade200, Colors.blueGrey.shade50]
                                            : [Colors.white, Colors.blue.shade50],
                                      ),
                                    ),
                                    child: ClipOval(
                                      child: auth.hasAvatarUrl
                                          ? Image.network(
                                          user!.avatar!,
                                          fit: BoxFit.cover,
                                      )
                                          : Center(
                                        child: Text(
                                          auth.initials(),
                                          style: const TextStyle(
                                            fontSize: 34,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.blueAccent,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    right: 6,
                                    bottom: 6,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: Colors.black87,
                                        borderRadius: BorderRadius.circular(22),
                                      ),
                                      padding: const EdgeInsets.all(6),
                                      child: const Icon(Icons.edit, size: 20, color: Colors.white),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 120),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    FadeTransition(
                      opacity: _fadeCtrl.drive(CurveTween(curve: Curves.easeOut)),
                      child: _glassCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('ID', style: Theme.of(context).textTheme.labelMedium),
                            const SizedBox(height: 4),
                            Text(user?.id ?? '未登录', style: Theme.of(context).textTheme.titleMedium),
                            const Divider(height: 28),
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('名称', style: Theme.of(context).textTheme.labelMedium),
                                      const SizedBox(height: 4),
                                      Text(
                                        user?.name ?? '未登录',
                                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                ),
                                if (auth.isAuthenticated)
                                  IconButton(
                                    tooltip: '编辑名称',
                                    onPressed: () => _editName(auth),
                                    icon: const Icon(Icons.edit_rounded),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _glassCard(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _statBlock(label: '会话', value: ChatCount.toString()),
                          _statBlock(label: '好友', value: ContactCount.toString()),
                          // _statBlock(label: '消息', value: '134'),
                        ],
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 12),
                    ),

                    /// 增加导出数据库按钮
                    // const SizedBox(height: 20),
                    // ElevatedButton(
                    //   onPressed: () async {
                    //     String result = await exportDb();
                    //     print(result);
                    //   },
                    //   child: Text("导出数据库"),
                    // ),


                    const SizedBox(height: 28),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      child: auth.isAuthenticated
                          ? ElevatedButton.icon(
                        key: const ValueKey('logout_btn'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          backgroundColor: Colors.redAccent,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 4,
                        ),
                        onPressed: () => _confirmLogout(auth),
                        icon: const Icon(Icons.power_settings_new_rounded),
                        label: const Text('注销'),
                      )
                          : const SizedBox.shrink(),

                      //问题： 手动导航无法注销后重新获得服务
                      // OutlinedButton(
                      //   key: const ValueKey('login_btn'),
                      //   onPressed: () => Navigator.of(context).pushReplacement(
                      //     MaterialPageRoute(builder: (_) => const LoginScreen()),
                      //   ),
                      //   style: OutlinedButton.styleFrom(
                      //     padding: const EdgeInsets.symmetric(vertical: 16),
                      //     shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      //   ),
                      //   child: const Text('登录'),
                      // ),
                    ),
                  ]),

                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _statBlock({required String label, required String value}) {
    return Column(
      children: [
        Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: Colors.grey.shade700)),
      ],
    );
  }
}

Future<int> getUserRelatedContactsCount(AuthService auth) async {
  final userId = auth.currentUser?.id;
  if (userId == null) return 0;
  final db = await DatabaseService.instance.database;
  final result = await db.rawQuery(
    'SELECT COUNT(*) as count FROM contacts WHERE contactId1 = ? OR contactId2 = ?',
    [userId, userId],
  );
  return Sqflite.firstIntValue(result) ?? 0;
}

Future<int> getUserRelatedChatsCount(AuthService auth) async {
  final userId = auth.currentUser?.id;
  if (userId == null) return 0;
  final db = await DatabaseService.instance.database;
  final result = await db.rawQuery(
    '''
    SELECT COUNT(*) as count
    FROM chats c
    ''',

  );
  return Sqflite.firstIntValue(result) ?? 0;
}

