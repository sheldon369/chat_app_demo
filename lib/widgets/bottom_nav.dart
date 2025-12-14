// dart
import 'package:flutter/material.dart';

class AppBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onChanged;
  const AppBottomNav({super.key, required this.currentIndex, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: currentIndex,
      selectedItemColor: Colors.blue,
      unselectedItemColor: Colors.grey,
      onTap: (i) {
        if (i != currentIndex) onChanged(i);
      },
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.chat_bubble_outline), label: '聊天'),
        BottomNavigationBarItem(icon: Icon(Icons.contacts), label: '通讯录'),
        BottomNavigationBarItem(icon: Icon(Icons.person_outline), label: '我'),
      ],
    );
  }
}
