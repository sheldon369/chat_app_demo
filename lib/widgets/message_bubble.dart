import 'dart:io';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../services/database_service.dart';

/// 消息气泡组件 - 显示单条消息
class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMe;
  final String? avatar; // 上层传入：users 表查到的 avatar，可能为空

  const MessageBubble({
    Key? key,
    required this.message,
    required this.isMe,
    this.avatar,
  }) : super(key: key);

  String get _displayName =>
      isMe ? '我' : ((message.senderName?.isNotEmpty ?? false) ? message.senderName! : '?');


  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMe) _buildAvatar(), // 左侧头像
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Text(
                  _displayName,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: isMe ? TextAlign.end : TextAlign.start,
                ),
                const SizedBox(height: 4),
                _buildMessageContent(context),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isMe) _buildAvatar(), // 右侧头像
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    return FutureBuilder<String?>(
      future: DatabaseService.instance.getUserAvatar(message.senderId), // 直接查 DB
      builder: (context, snapshot) {
        final avatar = snapshot.data;
        final hasAvatar = avatar != null && avatar.isNotEmpty;
        final initial = (_displayName.isNotEmpty ? _displayName[0] : '?').toUpperCase();
        return CircleAvatar(
          radius: 20,
          backgroundColor: Colors.blue,
          backgroundImage: hasAvatar ? NetworkImage(avatar) : null,
          child: hasAvatar ? null : Text(initial, style: const TextStyle(color: Colors.white)),
        );
      },
    );
  }

  /// 构建消息内容
  Widget _buildMessageContent(BuildContext context) {
    switch (message.type) {
      case MessageType.text:
        return _buildTextMessage();
      case MessageType.image:
        return _buildImageMessage();
      case MessageType.emoji:
        return _buildEmojiMessage();
    }
  }

  /// 文本消息
  Widget _buildTextMessage() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isMe ? Colors.blue : Colors.grey[300],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        message.content,
        style: TextStyle(
          color: isMe ? Colors.white : Colors.black87,
          fontSize: 16,
        ),
      ),
    );
  }

  /// 图片消息 - 使用优化的图片加载
  Widget _buildImageMessage() {
    debugPrint('img url = ${message.content}');
    return GestureDetector(
      onTap: () {},
      child: Container(
        constraints: const BoxConstraints(maxWidth: 200, maxHeight: 200),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            message.content,
            fit: BoxFit.cover,
            cacheWidth: 400,
            loadingBuilder: (c, child, progress) {
              if (progress == null) return child;
              return Container(
                width: 200,
                height: 200,
                color: Colors.grey[200],
                alignment: Alignment.center,
                child: Text('loading ${(progress.cumulativeBytesLoaded / (progress.expectedTotalBytes ?? 1) * 100).toStringAsFixed(0)}%'),
              );
            },
            errorBuilder: (context, error, stackTrace) {
              debugPrint('image load error: $error');
              debugPrint('stack: $stackTrace');
              return Container(
                width: 200,
                height: 200,
                color: Colors.grey[300],
                alignment: Alignment.center,
                child: const Icon(Icons.broken_image),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 表情消息
  Widget _buildEmojiMessage() {
    final path = message.content;
    final isAsset = path.startsWith('assets/'); // 资产路径判定

    if (isAsset) {
      return Image.asset(
        path,
        width: 80,
        height: 80,
        fit: BoxFit.contain,
        errorBuilder: (c, e, s) {
          debugPrint('[Emoji] 资产加载失败: $path');
          return const Icon(Icons.emoji_emotions, size: 48);
        },
      );
    } else {
      return Image.file(
        File(path),
        width: 80,
        height: 80,
        fit: BoxFit.contain,
        errorBuilder: (c, e, s) {
          debugPrint('[Emoji] 文件不存在: $path');
          return const Icon(Icons.emoji_emotions, size: 48);
        },
      );
    }
  }
}