import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/chat.dart';
import '../models/message.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/database_service.dart';
import '../widgets/message_bubble.dart';
import '../widgets/emoji_grid.dart';

/// 聊天详情页面 - 显示聊天消息和发送消息
class ChatScreen extends StatefulWidget {
  final Chat chat;

  const ChatScreen({Key? key, required this.chat}) : super(key: key);

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _showEmojiPicker = false;
  bool _isLoading = false;
  int _currentOffset = 0;
  static const int _pageSize = 50;

  final AuthService _auth = AuthService.instance;

  String get currentUserId =>
      AuthService.instance.currentUser?.id ?? '';

  String get currentUserName =>
      AuthService.instance.currentUser?.name ?? '我';

  // 状态里加
  Map<String, String?> _avatarCache = {};


  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    context.read<ChatService>().loadMessagesIfNeeded(widget.chat.id);
  }


  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 滚动监听 - 实现分页加载
  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMoreMessages();
    }
  }



  /// 加载更多消息（向上滚动时）
  Future<void> _loadMoreMessages() async {
    if (_isLoading) return;

    setState(() => _isLoading = true);

    await context.read<ChatService>().loadMessages(
      widget.chat.id,
      limit: _pageSize,
      offset: _currentOffset,
    );

    _currentOffset += _pageSize;

    setState(() => _isLoading = false);
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.chat.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () {
              // 更多选项
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 消息列表
          Expanded(
            child: GestureDetector(
              onTap: () {
                // 点击消息区域隐藏键盘和表情选择器
                FocusScope.of(context).unfocus();
                setState(() => _showEmojiPicker = false);
              },
              child: _buildMessageList(),
            ),
          ),
          // 输入区域
          _buildInputArea(),
          // 表情选择器
          if (_showEmojiPicker) _buildEmojiPicker(),
        ],
      ),
    );
  }

  /// 构建消息列表
  Widget _buildMessageList() {
    return Consumer<ChatService>(
      builder: (context, chatService, _) {
        final messages = chatService.messagesOf(widget.chat.id);

        if (messages.isEmpty) {
          return const Center(child: Text('暂无消息，开始聊天吧'));
        }

        return ListView.builder(
          controller: _scrollController,
          reverse: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: messages.length,
          itemBuilder: (context, index) {
            final message = messages[index];
            final isMe = message.senderId == currentUserId;

            return MessageBubble(
              message: message,
              isMe: isMe,
              avatar: _avatarCache[message.senderId],
            );
          },
        );
      },
    );
  }

  /// 构建输入区域
  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.2),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          // 表情按钮
          IconButton(
            icon: Icon(
              _showEmojiPicker ? Icons.keyboard : Icons.emoji_emotions,
              color: Colors.grey[700],
            ),
            onPressed: () {
              setState(() {
                _showEmojiPicker = !_showEmojiPicker;
              });
              if (_showEmojiPicker) {
                FocusScope.of(context).unfocus();
              }
            },
          ),
          // 文本输入框
          Expanded(
            child: TextField(
              controller: _messageController,
              decoration: InputDecoration(
                hintText: '输入消息...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Colors.grey[100],
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
              ),
              maxLines: null,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendTextMessage(),
              onTap: () {
                setState(() => _showEmojiPicker = false);
              },
            ),
          ),
          // 图片按钮
          IconButton(
            icon: Icon(Icons.image, color: Colors.grey[700]),
            onPressed: _sendImageMessage,
          ),
          // 发送按钮
          IconButton(
            icon: const Icon(Icons.send, color: Colors.blue),
            onPressed: _sendTextMessage,
          ),
        ],
      ),
    );
  }

  /// 构建表情选择器
  Widget _buildEmojiPicker() {
    final emojiPaths = List.generate(
      3175,
          (i) => 'assets/emojis/emoji_$i.png',
    );

    return EmojiGrid(
      emojiPaths: emojiPaths,
      onEmojiSelected: _sendEmojiMessage,
    );
  }

  /// 发送文本消息
  void _sendTextMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();

    final chatService = context.read<ChatService>();
    await chatService.sendTextMessage(
      widget.chat.id,
      currentUserId,
      currentUserName,
      text,
    );




  }

  /// 发送图片消息
  void _sendImageMessage() async {
    final chatService = context.read<ChatService>();
    await chatService.sendImageMessage(
      widget.chat.id,
      currentUserId,
      currentUserName,
    );



  }

  /// 发送表情消息
  void _sendEmojiMessage(String emojiPath) async {
    final chatService = context.read<ChatService>();
    await chatService.sendEmojiMessage(
      widget.chat.id,
      currentUserId,
      currentUserName,
      emojiPath,
    );

    setState(() => _showEmojiPicker = false);



  }
}