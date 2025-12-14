import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:third_app/screens/login_screen.dart';
import 'package:third_app/services/auth_service.dart';
import 'package:third_app/services/database_service.dart';
import 'services/chat_service.dart';
import 'screens/chat_list_screen.dart';
import 'screens/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();


  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // 1️⃣ AuthService：Provider 负责创建
        ChangeNotifierProvider<AuthService>(
          create: (_) {
            final auth = AuthService();
            auth.init(); // 初始化（读本地 token 等）
            return auth;
          },
        ),

        // 2️⃣ ChatService：监听 AuthService
        ChangeNotifierProxyProvider<AuthService, ChatService>(
          create: (_) => ChatService(authService: AuthService.instance),
          update: (_, authService, chatService) {
            final chat = chatService!;

            if (authService.currentUser != null) {
              chat.onLogin();
            } else {
              chat.onLogout();
            }

            return chat;
          },
        ),
      ],
      child: Consumer<AuthService>(
        builder: (_, auth, __) {
          return MaterialApp(
            title: '聊天应用',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              primarySwatch: Colors.blue,
              useMaterial3: true,
            ),
            home: auth.isAuthenticated
                ? const HomeShell()
                : const LoginScreen(),
          );
        },
      ),
    );
  }
}