/// 聊天会话模型
class Chat {
  //final控制变量只能被赋值一次，即不能对final变量重新赋值。
  //但如果final变量是一个可变对象(如List)，则该对象的属性是可以被修改的。
  //final 表示的是 引用不可变，而不是 对象内容不可变。 ——>“数据对象不变，状态变化靠新对象替换”
  final String id;
  final String name;
  final List<String> participantIds;
  //? 是空安全运算符，允许该变量为 null
  final String? lastMessage;//如果已经存在消息，我们通过provider传递
  final DateTime? lastMessageTime;
  final int unreadCount;//未读信息数

  Chat({
    //required：该具名参数必填，调用时必须写参数名。
    required this.id,
    required this.name,
    required this.participantIds,
    this.lastMessage,
    this.lastMessageTime,
    this.unreadCount = 0,
  });

  // 使用示例：
  // final chat1 = Chat(
  //   id: 'c1',
  //   name: '群聊',
  //   participantIds: ['u1', 'u2'],
  //   // lastMessage / lastMessageTime 不传则为 null
  //   // unreadCount 不传则为 0
  // );

  //把 Chat 实例序列化为可保存/传输的 Map，用于持久化传输
  Map<String, dynamic> toMap() {//Dart 的“类型推断”是 var；dynamic 是“关闭静态检查、运行期决定”的顶层类型，相当于 any
    return {
      'id': id,
      'name': name,
      //'participantIds': participantIds.join(','),
      // 把 List<String> 按给定分隔符拼接为一个单一字符串的方法。例如：['u1','u2'].join(',') -> 'u1,u2'。
      // 注意：这样会丢失列表结构，且当元素本身包含逗号时会产生歧义。
      'participantIds': participantIds.join(','),//直接在字典中存储列表List<string>
      'lastMessage': lastMessage,
      'lastMessageTime': lastMessageTime?.millisecondsSinceEpoch,//将 DateTime 转换为int型时间戳（毫秒数）（自1970-1-1 0：0 开始）
      'unreadCount': unreadCount,
    };
  }
//从 Map 反序列化为 Chat 实例
  factory Chat.fromMap(Map<String, dynamic> map) {//工厂构造：可以返回已有实例（缓存）、子类实例、进行类型判断或缓存优化，不一定要创建新的对象。
   // 使用 factory 是为了在反序列化时保留灵活性，目前它只是简单地把 Map 转换成 Chat 对象，但为未来的扩展留了口子。
    return Chat(
      id: map['id'] as String,
      name: map['name'] as String,
      participantIds: (map['participantIds'] as String).split(','),
      lastMessage: map['lastMessage'] as String?,
      lastMessageTime: map['lastMessageTime'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['lastMessageTime'])
          : null,
      unreadCount: (map['unreadCount'] as int?) ?? 0,
      //?? 是空合并运算符：左边为 null 时使用右边的默认值。这里表示缺省为 0。
    );
  }
}