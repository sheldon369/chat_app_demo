/// 消息类型枚举
enum MessageType {
  text,
  image,
  emoji,
}

/// 消息模型
class Message {
  final String id;
  final String chatId;
  final String senderId;
  final String senderName;// 该条冗余 ***
  final MessageType type;
  final String content; // 文本内容或图片路径
  final DateTime timestamp;
  final bool isRead;

  Message({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.senderName,
    required this.type,
    required this.content,
    required this.timestamp,
    this.isRead = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'chatId': chatId,
      'senderId': senderId,
      'senderName': senderName,
      'type': type.index,
      'content': content,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'isRead': isRead ? 1 : 0,
    };
  }

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      id: map['id'],
      chatId: map['chatId'],
      senderId: map['senderId'],
      senderName: map['senderName'],
      type: MessageType.values[map['type']],
      content: map['content'],
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp']),
      isRead: map['isRead'] == 1,
    );
  }

  Message copyWith({bool? isRead}) {//返回一个修改isRead的新版本Message,只传需要修改的字段，没传的自动沿用旧值
    //final msg2 = msg1.copyWith(isRead: true); msg1 保持不变；msg2 是新的 Message 实例，除了 isRead 变为 true，其他字段都一样。
    return Message(
      id: id,
      chatId: chatId,
      senderId: senderId,
      senderName: senderName,
      type: type,
      content: content,
      timestamp: timestamp,
      isRead: isRead ?? this.isRead,
    );
  }
}