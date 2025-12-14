import 'dart:io';
import 'package:flutter/material.dart';

/// 表情网格组件 - 优化了大量图片的加载性能
class EmojiGrid extends StatelessWidget {
  final List<String> emojiPaths;
  final Function(String) onEmojiSelected;

  const EmojiGrid({
    Key? key,
    required this.emojiPaths,
    required this.onEmojiSelected,
  }) : super(key: key);

  bool _isAsset(String path) => path.startsWith('assets/');

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 250,
      color: Colors.grey[100],
      child: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 8, // 每行8个表情
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        // 使用itemCount限制渲染数量
        itemCount: emojiPaths.length,
        // 使用addAutomaticKeepAlives保持滚动性能
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
        itemBuilder: (context, index) {
          return GestureDetector(
            onTap: () => onEmojiSelected(emojiPaths[index]),
            child: _EmojiItem(emojiPath: emojiPaths[index]),
          );
        },
      ),
    );
  }
}

/// 单个表情项 - 使用RepaintBoundary优化重绘性能
class _EmojiItem extends StatelessWidget {
  final String emojiPath;
  const _EmojiItem({required this.emojiPath});

  bool _isAsset(String path) => path.startsWith('assets/');

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (_isAsset(emojiPath)) {
      child = Image.asset(
        emojiPath,
        fit: BoxFit.contain,
        cacheWidth: 100,
        cacheHeight: 100,
        errorBuilder: (_, __, ___) => const Icon(Icons.emoji_emotions, size: 24),
      );
    } else if (File(emojiPath).existsSync()) {
      child = Image.file(
        File(emojiPath),
        fit: BoxFit.contain,
        cacheWidth: 100,
        cacheHeight: 100,
        errorBuilder: (_, __, ___) => const Icon(Icons.emoji_emotions, size: 24),
      );
    } else {
      child = const Icon(Icons.emoji_emotions, size: 24);
    }

    return RepaintBoundary(
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
        child: child,
      ),
    );
  }
}