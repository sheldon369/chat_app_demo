/// 用户模型
class User {
  final String id;
  final String? name;
  final String? avatar;//头像图片路径，可选
  final String? passwordHash; // 已哈希密码
  final String? token; // 新增，服务器验证令牌


  User({
    required this.id,
    this.name,
    this.avatar,
    this.passwordHash,
    this.token,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'avatar': avatar,
    };
  }

  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      id: map['id'],
      name: map['name'],
      avatar: map['avatar'],
    );
  }

  User copyWith({String? id, String? name, String? avatar, String? token}) {
    return User(
      id: id ?? this.id,
      name: name ?? this.name,
      avatar: avatar ?? this.avatar,
      token: token ?? this.token,
    );
  }


}